apiVersion: apps/v1
kind: Deployment
metadata:
  name: addon-lifecycle-operator
  namespace: addon-lifecycle-operator
  labels:
    app.kubernetes.io/name: addon-lifecycle-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: addon-lifecycle-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: addon-lifecycle-operator
    spec:
      serviceAccountName: addon-lifecycle-operator
      containers:
      - name: manager
        image: quay.io/openshift/addon-lifecycle-operator:latest
        args:
        - --enable-leader-election
        resources:
          limits:
            cpu: 100m
            memory: 30Mi
          requests:
            cpu: 100m
            memory: 20Mi
