FROM quay.io/mhildenb/dev-demo-base:1.1

USER root

# Add the argocd cli
RUN curl -SL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')/argocd-linux-amd64 && \
    chmod +x /usr/local/bin/argocd

# Add kustomize CLI (this is the same version of Kustomize the that current version of argo is using)
RUN cd /usr/local/bin && curl -s "https://raw.githubusercontent.com/\
kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash -s 3.6.1

# Add the kam CLI (for bootstrapping gitops applications)
RUN curl -SL -o /usr/local/bin/kam \
    https://github.com/redhat-developer/kam/releases/download/$(curl -s "https://api.github.com/repos/redhat-developer/kam/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')/kam_linux_amd64 && \
    chmod +x /usr/local/bin/kam

USER jboss

# this is done in the base image already (to support the demo shell images too), but for those that make
# local changes to .zshrc they should not have to rebuild the base
COPY .zshrc.example $HOME/.zshrc

ENV DEMO_HOME /workspaces/argocd-demo
