# Lab: <Title>

**Goal**  
What is the core skill or concept this lab demonstrates?  
_Example: Deploy and validate Kubernetes RBAC roles and role bindings._

**Related Issue:** #<issue_number>

---

## Prerequisites

- Tools / services required (CLI, SDKs, kubectl, az CLI, etc.)  
- Environment setup (cluster, subscription, test account, etc.)  

---

## Steps

1. Step 1 … (include CLI/code snippets if relevant)  

   ```bash
   kubectl create role pod-reader --verb=get,list --resource=pods
