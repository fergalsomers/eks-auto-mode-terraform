

provider "aws" {
  region = var.region
}


# Currently set to single zone (to reduce cross-az costs in testing).
# -- if you wan to coomend then comment out the filter clause and 
# -- uncomment the commented out one that filters out local zones
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  #filter {
  #  name   = "zone-name"
  #  values = ["us-east-1a"]
  #}
}

locals {
  cluster_name = "kombinant-eks-${random_string.suffix.result}"
  avail_azs = data.aws_availability_zones.available.names
  num_azs = min(length(local.avail_azs), 3)                # we want at most 3 zones (but can work with less)
  azs = slice(local.avail_azs, 0, local.num_azs)

  private_subnets = slice(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"], 0, local.num_azs)
  public_subnets  = slice(["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"], 0, local.num_azs)
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.18.1"

  name = "education-vpc"

  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1                # Tag subnet for public LB
    "mapPublicIpOnLaunch"    = "TRUE"           # Tag subnet for public routable IP
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1                    # Tag subnet for private LB
    "mapPublicIpOnLaunch"             = "FALSE"              # Well duh! (not necessary since this is the default)
    "karpenter.sh/discovery"          = local.cluster_name   # Allows karpenter to select attach instances in subnet
    "kubernetes.io/role/cni"          = "1"                  # Allows nodes to have CNI auto installed. 
  }

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"   # Subnets in which to place the LB (i.e. can be placed in all)
  }
}

resource "aws_eks_cluster" "cluster" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  #version  = "1.32"  // this is optional - so this will use the latest version

  access_config {
    authentication_mode = "API"
    bootstrap_cluster_creator_admin_permissions = true  # for testing lets be the admin
  }


  bootstrap_self_managed_addons = false


  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    security_group_ids      = []
    endpoint_private_access = "true"
    endpoint_public_access  = "true"
  }


  compute_config {
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.node.arn
  }


  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }


  storage_config {
    block_storage {
      enabled = true
    }
  }

  # Ensure that IAM Role permissions are created before and deleted
  # after EKS Cluster handling. Otherwise, EKS will not be able to
  # properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSComputePolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSBlockStoragePolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSLoadBalancingPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSNetworkingPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,  # added for lb
    aws_iam_role_policy_attachment.cluster_AmazonEKSServicePolicy,
  ]
}

resource "aws_eks_addon" "example" {
  cluster_name = aws_eks_cluster.cluster.name
  addon_name   = "metrics-server"
}


resource "aws_iam_role" "node" {
  name = "eks-auto-node-example"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole"]
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodeMinimalPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryPullOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.node.name
}


resource "aws_iam_role" "cluster" {
  name = "eks-cluster-example"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSComputePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSBlockStoragePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSLoadBalancingPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSNetworkingPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.cluster.name
}


#
# EKS POD-IDENTITY Example (simpler than IRSA) 
#

# Define a policy that allows pods on EKS to assume role
data "aws_iam_policy_document" "pod_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

# Define a role and the policy controls which principals can assume it.  
resource "aws_iam_role" "pod_s3_read" {
  name               = "pod-s3-read"
  assume_role_policy = data.aws_iam_policy_document.pod_assume_role.json
}

# Attach the S3 policy to the role
resource "aws_iam_role_policy_attachment" "s3_read_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  role       = aws_iam_role.pod_s3_read.name
}

# Associate the EKS POD with ServiceAccount example-sa - in namespace example can assume this role in this cluster
resource "aws_eks_pod_identity_association" "example" {
  cluster_name    = aws_eks_cluster.cluster.name
  namespace       = "example"
  service_account = "example-sa"
  role_arn        = aws_iam_role.pod_s3_read.arn
}