# Image source for the vendored aeroncache Helm charts.
#
# Unlike upstream (which builds images into the local Docker/Minikube daemon and runs them
# with pullPolicy Never), this repo ALWAYS pulls released images from the GitHub Container
# Registry. versions.env pins the release; the GHCR image tag is that release with the
# leading "v" stripped (see versions.env). kind and minikube pull these public images
# directly from the internet — no `kind load` / `minikube image load` needed.
#
# Requires versions.env to have been included first (pattern.mk does this).
#
# Overridable (command-line values propagate to sub-makes):
#   GHCR_REGISTRY=ghcr.io
#   GHCR_OWNER=bhf
#   GHCR_TAG=<release-without-v>      # defaults from AERONCACHE_VERSION
#   GHCR_PULL_POLICY=IfNotPresent     # CI sets Always (the -SNAPSHOT tag is mutable upstream)
#   IMAGE_PULL_SECRET=<name>          # only needed if the packages are made private

GHCR_REGISTRY    ?= ghcr.io
GHCR_OWNER       ?= bhf
GHCR_PULL_POLICY ?= IfNotPresent
# Strip a leading "v" from the pinned release to get the GHCR image tag.
GHCR_TAG         ?= $(AERONCACHE_VERSION:v%=%)

# $(call ghcr_image,<image-name>,<values-key>) -> the helm --set flags that point the Helm
# values key <values-key> (e.g. `image`, or `clustertools.image`) at
# ghcr.io/<owner>/<image-name>:<tag>.
#   e.g. $(call ghcr_image,aeroncache-monolith,image)
ghcr_image = --set $(2).repository=$(GHCR_REGISTRY)/$(GHCR_OWNER)/$(1) \
             --set $(2).pullPolicy=$(GHCR_PULL_POLICY) \
             --set $(2).tag=$(GHCR_TAG)

# Optional imagePullSecret for private GHCR packages; empty unless IMAGE_PULL_SECRET is set.
ghcr_secret = $(if $(IMAGE_PULL_SECRET),--set imagePullSecrets[0].name=$(IMAGE_PULL_SECRET))
