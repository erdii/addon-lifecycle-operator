FROM scratch

WORKDIR /
COPY passwd /etc/passwd
COPY addon-lifecycle-operator-manager /

USER "noroot"

ENTRYPOINT ["/addon-lifecycle-operator-manager"]
