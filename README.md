# AWS VPC Peering Project

Student project from the EWB Cloud Labs AWS Cloud Computing Internship (EWB Edutech Pvt. Ltd.).

## Overview

Two private VPCs connected with VPC peering. One public bastion host in VPC A is used for SSH administration. Both application servers stay private (no public IP).

| Resource | CIDR / address |
|---|---|
| VPC A (`ewb-vpc-a`) | 10.10.0.0/16 |
| Public subnet A (`ewb-a-public`) | 10.10.1.0/24 (bastion 10.10.1.10) |
| Private subnet A (`ewb-a-private`) | 10.10.2.0/24 (App-A 10.10.2.10) |
| VPC B (`ewb-vpc-b`) | 10.20.0.0/16 |
| Private subnet B (`ewb-b-private`) | 10.20.1.0/24 (App-B 10.20.1.10) |

Region: Asia Pacific (Sydney) `ap-southeast-2`

## What I built

- 2 VPCs with non-overlapping CIDRs, 3 subnets, 1 internet gateway (VPC A only)
- 3 custom route tables with explicit subnet associations
- VPC peering connection (requested, accepted) with routes on both sides
- 3 security groups scoped to /32 sources (no 0.0.0.0/0)
- 3 EC2 instances (Amazon Linux 2023, t3.micro) and SSH access through the bastion using ProxyJump

## Tests

1. Baseline before peering: ping App-A to App-B, 100% packet loss
2. After peering and routes: forward ping App-A to App-B, 0% packet loss
3. Reverse ping App-B to App-A, 0% packet loss, plus SSH to App-B through the bastion
4. Controlled failure: removed the ICMP rule on App-B, ping failed; restored it, ping recovered

## Files

- `OmPanwar_EWB_VPC_Peering.pdf` - full project report with screenshots
- `ewb_vpc_peering.sh` - AWS CLI script used to build the lab (build, peer, fail, restore, cleanup)

## Key concepts

- VPC peering is one-to-one and non-transitive
- Routes are needed on both sides (forward and return path)
- An Active peering connection alone does not allow traffic; route tables and security groups must also allow it
- Security groups are stateful, so replies to allowed requests are permitted automatically

All resources were deleted after the project to avoid charges.
