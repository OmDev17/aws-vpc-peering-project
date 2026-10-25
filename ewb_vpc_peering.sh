#!/usr/bin/env bash
# EWB VPC Peering lab - run in AWS CloudShell (ap-south-1) or any shell with AWS CLI configured.
# Usage: bash ewb_vpc_peering.sh build     -> creates everything EXCEPT peering (do baseline test)
#        bash ewb_vpc_peering.sh peer      -> peering + routes
#        bash ewb_vpc_peering.sh fail      -> controlled ICMP failure
#        bash ewb_vpc_peering.sh restore   -> restore the ICMP rule
#        bash ewb_vpc_peering.sh cleanup   -> delete everything
set -euo pipefail
export AWS_DEFAULT_REGION=ap-south-1
AZ=ap-south-1a
STUDENT="YOUR_NAME"          # <-- change this
ENVF=./ewb_ids.env
TAGS="Key=Project,Value=EWB-VPC-Peering Key=Student,Value=${STUDENT}"
[ -f $ENVF ] && source $ENVF
save() { echo "$1=${!1}" >> $ENVF; }
tag() { # tag <resource-id> <name>
  aws ec2 create-tags --resources "$1" --tags Key=Name,Value="$2" $TAGS; }

build() {
  MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32; echo "Your IP: $MYIP"

  # VPC A
  VPC_A=$(aws ec2 create-vpc --cidr-block 10.10.0.0/16 --query Vpc.VpcId --output text); tag $VPC_A ewb-vpc-a; save VPC_A
  SUB_A_PUB=$(aws ec2 create-subnet --vpc-id $VPC_A --cidr-block 10.10.1.0/24 --availability-zone $AZ --query Subnet.SubnetId --output text); tag $SUB_A_PUB ewb-a-public; save SUB_A_PUB
  SUB_A_PRIV=$(aws ec2 create-subnet --vpc-id $VPC_A --cidr-block 10.10.2.0/24 --availability-zone $AZ --query Subnet.SubnetId --output text); tag $SUB_A_PRIV ewb-a-private; save SUB_A_PRIV
  IGW=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text); tag $IGW ewb-igw-a; save IGW
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_A
  RT_A_PUB=$(aws ec2 create-route-table --vpc-id $VPC_A --query RouteTable.RouteTableId --output text); tag $RT_A_PUB ewb-rt-a-public; save RT_A_PUB
  aws ec2 create-route --route-table-id $RT_A_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
  aws ec2 associate-route-table --route-table-id $RT_A_PUB --subnet-id $SUB_A_PUB >/dev/null
  RT_A_PRIV=$(aws ec2 create-route-table --vpc-id $VPC_A --query RouteTable.RouteTableId --output text); tag $RT_A_PRIV ewb-rt-a-private; save RT_A_PRIV
  aws ec2 associate-route-table --route-table-id $RT_A_PRIV --subnet-id $SUB_A_PRIV >/dev/null

  # VPC B
  VPC_B=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --query Vpc.VpcId --output text); tag $VPC_B ewb-vpc-b; save VPC_B
  SUB_B_PRIV=$(aws ec2 create-subnet --vpc-id $VPC_B --cidr-block 10.20.1.0/24 --availability-zone $AZ --query Subnet.SubnetId --output text); tag $SUB_B_PRIV ewb-b-private; save SUB_B_PRIV
  RT_B_PRIV=$(aws ec2 create-route-table --vpc-id $VPC_B --query RouteTable.RouteTableId --output text); tag $RT_B_PRIV ewb-rt-b-private; save RT_B_PRIV
  aws ec2 associate-route-table --route-table-id $RT_B_PRIV --subnet-id $SUB_B_PRIV >/dev/null

  # Security groups
  SG_BASTION=$(aws ec2 create-security-group --group-name ewb-sg-bastion --description "EWB bastion" --vpc-id $VPC_A --query GroupId --output text); tag $SG_BASTION ewb-sg-bastion; save SG_BASTION
  SG_APP_A=$(aws ec2 create-security-group --group-name ewb-sg-app-a --description "EWB app A" --vpc-id $VPC_A --query GroupId --output text); tag $SG_APP_A ewb-sg-app-a; save SG_APP_A
  SG_APP_B=$(aws ec2 create-security-group --group-name ewb-sg-app-b --description "EWB app B" --vpc-id $VPC_B --query GroupId --output text); tag $SG_APP_B ewb-sg-app-b; save SG_APP_B
  aws ec2 authorize-security-group-ingress --group-id $SG_BASTION --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP_A --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.10.1.10/32}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP_A --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.20.1.10/32}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP_B --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.10.1.10/32}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id $SG_APP_B --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]" >/dev/null

  # Key pair (private key stays local)
  mkdir -p ~/.ssh
  aws ec2 create-key-pair --key-name ewb-lab --query KeyMaterial --output text > ~/.ssh/ewb-lab.pem
  chmod 400 ~/.ssh/ewb-lab.pem

  # Instances
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  launch() { # name subnet sg ip public(--associate-public-ip-address|--no-associate-public-ip-address)
    aws ec2 run-instances --image-id $AMI --instance-type t3.micro --key-name ewb-lab \
      --subnet-id $2 --security-group-ids $3 --private-ip-address $4 $5 \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$1},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT}]" \
      --query 'Instances[0].InstanceId' --output text; }
  BASTION_ID=$(launch ewb-bastion $SUB_A_PUB $SG_BASTION 10.10.1.10 --associate-public-ip-address); save BASTION_ID
  APP_A_ID=$(launch ewb-app-a $SUB_A_PRIV $SG_APP_A 10.10.2.10 --no-associate-public-ip-address); save APP_A_ID
  APP_B_ID=$(launch ewb-app-b $SUB_B_PRIV $SG_APP_B 10.20.1.10 --no-associate-public-ip-address); save APP_B_ID
  aws ec2 wait instance-running --instance-ids $BASTION_ID $APP_A_ID $APP_B_ID
  BASTION_IP=$(aws ec2 describe-instances --instance-ids $BASTION_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

  cat > ~/.ssh/config.ewb <<EOF
Host ewb-bastion
    HostName $BASTION_IP
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
Host ewb-app-a
    HostName 10.10.2.10
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
Host ewb-app-b
    HostName 10.20.1.10
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
EOF
  echo "Bastion public IP: $BASTION_IP"
  echo "SSH config written to ~/.ssh/config.ewb (copy into ~/.ssh/config on the machine you SSH from)."
  echo "NOW do the baseline: ssh ewb-app-a ; ping -c 4 10.20.1.10  (expect NO replies). Screenshot it. Then run: bash $0 peer"
}

peer() {
  PCX=$(aws ec2 create-vpc-peering-connection --vpc-id $VPC_A --peer-vpc-id $VPC_B --query VpcPeeringConnection.VpcPeeringConnectionId --output text); save PCX
  tag $PCX ewb-a-b-peer
  aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids $PCX
  aws ec2 create-route --route-table-id $RT_A_PRIV --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 create-route --route-table-id $RT_B_PRIV --destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 create-route --route-table-id $RT_A_PUB  --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids $PCX --query 'VpcPeeringConnections[0].Status.Code'
  echo "Peering ACTIVE + routes added. Run the tests (see README steps) then: bash $0 fail"
}

fail()    { aws ec2 revoke-security-group-ingress --group-id $SG_APP_B --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]"; echo "ICMP rule removed. From App-A: ping -c 4 10.20.1.10 (expect failure)"; }
restore() { aws ec2 authorize-security-group-ingress --group-id $SG_APP_B --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]"; echo "Rule restored. Re-run ping (expect success)"; }

cleanup() {
  aws ec2 terminate-instances --instance-ids $BASTION_ID $APP_A_ID $APP_B_ID >/dev/null
  aws ec2 wait instance-terminated --instance-ids $BASTION_ID $APP_A_ID $APP_B_ID
  [ -n "${PCX:-}" ] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null || true
  aws ec2 delete-security-group --group-id $SG_BASTION
  aws ec2 delete-security-group --group-id $SG_APP_A
  aws ec2 delete-security-group --group-id $SG_APP_B
  for rt in $RT_A_PUB $RT_A_PRIV $RT_B_PRIV; do
    for a in $(aws ec2 describe-route-tables --route-table-ids $rt --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --association-id $a; done
    aws ec2 delete-route-table --route-table-id $rt
  done
  aws ec2 delete-subnet --subnet-id $SUB_A_PUB
  aws ec2 delete-subnet --subnet-id $SUB_A_PRIV
  aws ec2 delete-subnet --subnet-id $SUB_B_PRIV
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_A
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW
  aws ec2 delete-vpc --vpc-id $VPC_A
  aws ec2 delete-vpc --vpc-id $VPC_B
  aws ec2 delete-key-pair --key-name ewb-lab; rm -f ~/.ssh/ewb-lab.pem
  echo "Cleanup done. Screenshot the console filtered by tag Project=EWB-VPC-Peering showing nothing left."
}

"${1:?usage: build|peer|fail|restore|cleanup}"
