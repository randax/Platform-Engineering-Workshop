# Deliberately tiny: one static page served by busybox httpd.
# The base image comes from YOUR in-cluster Zot registry — seed it first
# (see the module README): crane copy localhost:5001/library/busybox:1.37.0
# into zot.cloudbox.k8s.test/library/busybox:1.37.0. Your platform builds FROM
# your own registry — fully offline.
FROM zot.zot.svc.cluster.local:5000/library/busybox:1.37.0
COPY index.html /www/index.html
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
