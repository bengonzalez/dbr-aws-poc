# POC for Databricks deployment in AWS

### So far:  

What we have before we get the
```  
AWS VPC  
├── Public subnet  
├── Private subnet A  
├── Private subnet B  
├── NAT Gateway  
├── Databricks security group  
├── S3 Gateway endpoint  
└── KMS Interface endpoint  
  
S3  
├── databricks-poc-data-556940913059  
│   └── Existing encrypted data bucket  
│  
└── databricks-poc-root-556940913059  
    └── Databricks workspace root storage  
        ├── Versioning  
        ├── Public access blocked  
        ├── Bucket owner enforced  
        ├── SSE-S3  
        └── Databricks-generated bucket policy  
  
Databricks Account  
├── Credentials configuration  
│   └── databricks-poc-credentials  
│  
└── Storage configuration  
    └── databricks-poc-storage  
```

Progression:
```
Credentials
    ↓
Storage
    ↓
Network
    ↓
Encryption / CMK
    ↓
Workspace
```
Where we are:
```
Credentials ✅
Storage     ✅
Network     ← NEXT
CMK         ← after network
Workspace   ← later
```