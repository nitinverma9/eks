locals {
  addon = {
    "coredns"            = "v1.10.1-eksbuild.1",
    "kube-proxy"         = "v1.27.1-eksbuild.1",
    "vpc-cni"            = "v1.13.0-eksbuild.1",
    "aws-ebs-csi-driver" = "v1.19.0-eksbuild.2"
  }
  addon_role = {
    "vpc-cni"            = "AmazonEKSVPCCNIRole",
    "aws-ebs-csi-driver" = "AmazonEKSTFEBSCSIRole"
  }
}
provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "education-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name = "education-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.5.1"

  cluster_name    = local.cluster_name
  cluster_version = "1.27"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name           = "node-group-1"
      instance_types = ["t3a.small"]
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      min_size     = 1
      max_size     = 3
      desired_size = 2
    }

    two = {
      name           = "node-group-2"
      instance_types = ["t3a.small"]
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}


# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_iam_policy" "vpc_cni_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

module "addon_roles" {
  for_each                      = local.addon_role
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "4.7.0"
  create_role                   = true
  role_name                     = "${each.value}-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = each.key == "vpc-cni" ? [data.aws_iam_policy.vpc_cni_policy.arn] : [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = each.key == "vpc-cni" ? ["system:serviceaccount:kube-system:aws-node"] : ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "this" {
  for_each                 = local.addon
  cluster_name             = module.eks.cluster_name
  addon_name               = each.key
  addon_version            = each.value
  service_account_role_arn = each.key == "vpc-cni" ? module.addon_roles["vpc-cni"].iam_role_arn : (each.key == "aws-ebs-csi-driver" ? module.addon_roles["aws-ebs-csi-driver"].iam_role_arn : "")
  resolve_conflicts        = "OVERWRITE"
  tags = {
    "eks_addon" = each.key
    "terraform" = "true"
  }
}