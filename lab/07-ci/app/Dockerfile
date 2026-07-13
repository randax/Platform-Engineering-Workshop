# Deliberately tiny: one static page served by busybox httpd.
# Base image is pinned and in the workshop pre-pull list (scripts/images.txt).
FROM docker.io/library/busybox:1.37.0
COPY index.html /www/index.html
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
