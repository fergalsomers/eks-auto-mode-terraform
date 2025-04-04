<!---
Copyright (c) [2024] Fergal Somers
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->

# Context  <!-- omit from toc -->
This contains example terraform files that can be used to create a AWS EKS auto-mode cluster. 
EKS allows for a lot of different types of clusters depending on the level of customization and 
control you need over things like AMI's and node-group management. However, for teams that
want their EKS clusters to be largely self-managing to minimise operational overhead, then auto-mode is the way to go.
EKS auto-mode automates kubernetes updates and scalability out of the box. Automated on-demand scalability is one way to 
minimise costs of running cluster by continually rightsizing the number and type of EC2 instances (nodes) required.  

The cost of auto-mode is:

- Less control (AWS automates Kubernetes version upgrades).
- Nodes are regularly cycled - both to rightsize nodes (e.g. more efficient bin-packing), and to perform K8 upgrades.
This means your services need to be cloud-native (run multiple replicas, tolerate [disruption](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)). It is important in this
world to specify per-service [Pod Disruption Budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/#pod-disruption-budgets) to ensure your workloads can handle disruption. 

You can extend this scheme if necessasary, to mix and match auto-mode and Karpenter-managed node-pools, should you
require more control over node provisioning. However, this is an advanced / niche use-case. 
If you do go down this road, [AWS EKS terraform provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) code here can be extended to handle such a use-case.  

# Terraform and State files

There is a lots of good information on this topic already, but to summarise: When you run terraform it creates a state file containing references to all the things it creates. This file is used:

- When you want to teardown (destroy) your cluster (state file indexes all-the-things) 
- When you make changes to your terraform (state file is used to compute the diff to be applied). 

So the state file is effectively terraforms memory. There are a couple of knock on consquences to this

- Don't lose the state file! Back it up somewhere (e.g. S3). Alternatively use a hosted service (e.g. terraform enterprise).
- Don't make changes outside of terraform to resources controlled by terraform. Terraform is brittle and cannot handle out-of-band changes. All it takes is for one spririted developer to make 'just one quick change via the console or CLI' and your existing terraform can no longer be applied. 
- Keep your terraform simple. This includes as you evolve your terraform files over time. Terraform can handle many changes, but some it cannot, or at least they need to be 
aequenced carefully and iteratively. Try and maintain simplicity (esspecially if you don't wan to have to have any downtime where you rip and replace a cluster).



*Contents*

- [Terraform and State files](#terraform-and-state-files)
- [Pre-requisites](#pre-requisites)
- [Setup your AWS credentials](#setup-your-aws-credentials)
- [How to install](#how-to-install)
- [Create a kubeconfig](#create-a-kubeconfig)
- [Verify Kubectl is setup](#verify-kubectl-is-setup)
- [Deploy the sample deployment](#deploy-the-sample-deployment)
- [To deploy public ingress](#to-deploy-public-ingress)
- [To deploy the IAM example Kubernetes Job](#to-deploy-the-iam-example-kubernetes-job)
- [To clean up](#to-clean-up)
- [To Do](#to-do)
- [References](#references)
- [Notes](#notes)






# Pre-requisites

1. Install [Docker](https://docs.docker.com/engine/install/)
1. Install [kind](https://kind.sigs.k8s.io/) - for mac "brew install kind"
1. Install [kubectl](https://kubernetes.io/docs/reference/kubectl/) - for mac "brew install kubectl"
1. Install [git](https://git-scm.com/) - git comes with Xcode on mac. 
1. Install [terraform](https://registry.terraform.io/) - for mac "brew install terraform" 
1. Install [AWS CLI](https://docs.aws.amazon.com/cli/)  - follow instructions on https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html 


# Setup your AWS credentials

You will need an AWS account and a user in that account with admin level privileges - you can create these in the AWS console. 

To use the AWS CLI you will need to configure that user's credentials - see https://docs.aws.amazon.com/cli/v1/userguide/cli-configure-files.html .
This has best practices you can follow depending on your setup. 

The simplest / most direct (ok for testing) way is to get an ACCESS key for your user (either short-term or long-term) and configure it on the command line, e.g. 

```bash
export AWS_ACCESS_KEY_ID=<SOME KEY ID>
export AWS_SECRET_ACCESS_KEY=<SOME ACCESS KEY>
```


# How to install

Clone the repo and 

```bash
git clone https://github.com/fergalsomers/eks-auto-mode-terraform
cd eks-auto-mode-terraform/terraform

terraform init
terraform apply
```

# Create a kubeconfig

You will need this to access the cluster

```bash
aws eks --region $(terraform output -raw region) update-kubeconfig \
    --name $(terraform output -raw cluster_name)
```

# Verify Kubectl is setup

```bash
kubectl cluster-info
```

This should respond with a message `Kubernetes control plane is running at ... ` if everything is fine. 

# Deploy the sample deployment

``` bash
kubectl apply -f ../resources/ingress-example/deployment.yaml
kubectl get pods 
```

This should start the pods, to verify, port-forward:

```bash
kubectl port-forward service/service-hello-world 8080:80 
```

and point your browser at http://localhost:8080/ - if everything is OK it should print hello world. 

# To deploy public ingress

```bash
kubectl apply -f ../resources/ingress-example/ingress.yaml
```

This will provision an ELB. You can get the public address using this command

```bash
kubectl get ingress ingress-hello-world-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

And you can curl the endpoint using the following

```bash
curl -k `kubectl get ingress ingress-hello-world-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
```

# To deploy the IAM example Kubernetes Job

```bash
kubect deploy -f ../resources/iam-example/example-job.yaml
```

This will create the `example` namespace and a sample job that lists S3. 

In order for this Job to `COMPLETE` correctly, the jobs's K8 ServiceAccount `example-sa` has been associated
with the IAM role `pod-s3-read` (which grants S3 view access).  This uses terraform's
[EKS pod-identity association](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association#cluster_name-2)
resource to accomplish this. For more details see the terraform script in the [/terraform/main.tf](/terraform/main.tf).

You can watch the status of the job as follows:

```bash
kubectl get job -n example -w
```

Press Control-C to exit out of this watch. 

You can view the logs associated with the pods that run this job as follow:

```bash
kubectl logs -n example -l app=example-job
```

# To clean up

```bash
kubectl delete -k ../resources
terraform destroy
```

# To Do

-  Add option for non auto-mode
-  Show how to configure AWS group for access


# References

1. https://registry.terraform.io/providers/hashicorp/aws/latest/docs  - AWS EKS terraform provider. 
1. https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster#eks-cluster-with-eks-auto-mode - AWS EKS resource - auto-mode example
1. https://marcincuber.medium.com/amazon-eks-auto-mode-with-terraform-8b15c2f1aa62 - Article on Auto-mode
1. https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest - AWS VPC terraform module

# Notes

1. We have enable the whoever runs the script to be the admin (this helps us avoid having to setup groups and configure EKS), however, this is only really for testing.  Define a IAM group and associate it with arn:aws:iam::ACCOUNT_ID:role/EKS-Admin-Role