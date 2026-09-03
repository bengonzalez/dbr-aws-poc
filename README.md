# POC for Databricks deployment in AWS


### What we will build in personal AWS Account:  
┌───────────────────────────────────────────────┐  
│              Personal AWS Account             │  
│                                               │  
│  ┌─────────────────────────────────────────┐  │  
│  │                  VPC                    │  │  
│  │                                         │  │  
│  │  Public             Private             │  │  
│  │  ┌───────┐          ┌───────────────┐   │  │  
│  │  │ NAT   │──────────│  Databricks   │   │  │  
│  │  └───────┘          │   Compute     │   │  │  
│  │                     └───────┬───────┘   │  │  
│  │                             │           │  │  
│  │                     ┌───────▼───────┐   │  │  
│  │                     │      S3       │   │  │  
│  │                     └───────────────┘   │  │  
│  │                                         │  │  
│  │  KMS │ CloudTrail │ Flow Logs │ IAM     │  │  
│  └─────────────────────────────────────────┘  │  
└───────────────────────────────────────────────┘  

### Target TSA Architecture:  
                     DHS / TSA
                         │
                    Enterprise IdP
                         │
                        SSO
                         │
                         ▼
              ┌─────────────────────┐
              │ DHS/TSA Network     │
              └──────────┬──────────┘
                         │
                  Private Connectivity
                         │
                         ▼
══════════════════════════════════════════════════
                 AWS GOVCLOUD
══════════════════════════════════════════════════
                         │
                  ┌──────▼───────┐
                  │     VPC      │
                  │              │
                  │ Private      │
                  │ Subnets      │
                  │              │
                  │ ┌──────────┐ │
                  │ │Databricks│ │
                  │ └────┬─────┘ │
                  │      │       │
                  │ PrivateLink  │
                  │      │       │
                  │ ┌────▼────┐  │
                  │ │   S3    │  │
                  │ └─────────┘  │
                  │              │
                  │ KMS          │
                  │ CloudTrail   │
                  │ Flow Logs    │
                  └──────────────┘

