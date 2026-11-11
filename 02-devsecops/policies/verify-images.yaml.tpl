# Admission check: a pod in a labelled namespace may only run images our CI signed.
# 02-signing.sh replaces the public key placeholder and applies this.
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-demo-images
spec:
  validationActions: [Deny]
  # Opt-in by label, so a Kyverno outage can only block these namespaces, never the platform.
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security.k8s-learning/verify-images: "true"
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "secure-registry:5000/*"
  # Git already pins the digest, so Kyverno has nothing to rewrite.
  validationConfigurations:
    mutateDigest: false
    verifyDigest: true
    required: true
  attestors:
    - name: ci
      cosign:
        key:
          data: |
__COSIGN_PUB__
        # No public transparency log in a private lab: the key alone proves who signed.
        ctlog:
          insecureIgnoreTlog: true
          insecureIgnoreSCT: true
  validations:
    # Signature checks only apply to images matching the glob above. Without this rule,
    # pulling from any other registry would skip signing altogether.
    - expression: >-
        object.spec.containers.all(c, c.image.startsWith('secure-registry:5000/')) &&
        (!has(object.spec.initContainers) ||
         object.spec.initContainers.all(c, c.image.startsWith('secure-registry:5000/'))) &&
        (!has(object.spec.ephemeralContainers) ||
         object.spec.ephemeralContainers.all(c, c.image.startsWith('secure-registry:5000/')))
      message: images must come from secure-registry:5000
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.ci])).all(e, e > 0)
      message: image is not signed by the CI key
