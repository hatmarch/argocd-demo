# Payment as Knative Service

This folder contains assets for updating the infrastructure of the coolstore payment service to serverless

1. Services.yaml: This is the definition of the Knative Service.  Note that this is immutable and can only be deployed to an environment once via argo with this name
1. Deployment.yaml: Represents the kafka knative eventing that triggers the service