COMPONENT_DESCRIPTOR := ocm/component-descriptor.yaml
COMPONENT_NAME       := github.com/bwi/powerdns-ocm
COMPONENT_VERSION    := 0.1.0-poc
CTF_FILE             := ocm/ctf.tar
CTF_BUNDLED          := ocm/ctf-bundled.tar
REGISTRY             ?= ghcr.io/bwi/powerdns-ocm
OCM_BIN              ?= ocm
OCM_ADD_FLAGS        ?=
KUBECTL_BIN          ?= kubectl

.PHONY: help ocm-build ocm-bundle ocm-validate ocm-push deploy localize deploy-air-gap print-component-ref

help:
	@echo "Targets:"
	@echo "  ocm-build       Build OCM component archive from descriptor (external image refs)"
	@echo "  ocm-bundle      Bundle images into archive for air-gap transport (requires ocm-build)"
	@echo "  ocm-validate    Validate the component archive with 'ocm get componentversion'"
	@echo "  ocm-push        Push bundled archive to OCI registry (set REGISTRY=...)"
	@echo "  deploy          Apply all Kubernetes manifests via kustomize (online, upstream images)"
	@echo "  localize        Generate air-gap overlay for a private registry (set REGISTRY=...)"
	@echo "  deploy-air-gap  Apply manifests via the air-gap overlay (run 'localize' first)"

ocm-build: $(COMPONENT_DESCRIPTOR)
	rm -rf $(CTF_FILE)
	$(OCM_BIN) add componentversions $(OCM_ADD_FLAGS) --type tar --create --file $(CTF_FILE) $(COMPONENT_DESCRIPTOR)

ocm-bundle: ocm-build
	rm -rf $(CTF_BUNDLED)
	$(OCM_BIN) transfer componentarchive --copy-resources $(CTF_FILE) $(CTF_BUNDLED)

ocm-validate: ocm-build
	$(OCM_BIN) get componentversion $(CTF_FILE)//$(COMPONENT_NAME):$(COMPONENT_VERSION)

ocm-push: ocm-bundle
	$(OCM_BIN) transfer componentarchive $(CTF_BUNDLED) oci://$(REGISTRY)

deploy:
	$(KUBECTL_BIN) apply -k deploy/

localize:
	./hack/localize-images.sh --registry $(REGISTRY)

deploy-air-gap:
	$(KUBECTL_BIN) apply -k deploy/overlays/air-gap/

print-component-ref:
	@echo $(COMPONENT_NAME):$(COMPONENT_VERSION)
