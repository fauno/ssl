default: all

# Domains this node will be serving, one per line without comments, the
# first domain is assumed to be the main domain
DOMAIN_LIST = $(PWD)/domains
# How you call the inhabitants of the node
PEOPLE = pirates
# Base group of the PEOPLE
GROUP = ship
# Hostname
HOST = $(shell hostname)
# The main domain
FQDN = $(shell head -n1 $(DOMAIN_LIST))

# Where the config files are stored
ETC ?= /etc
# Security level for GnuTLS
SECURITY ?= high
# Bundler flags
BUNDLE ?= --path=vendor

# Diffie-Hellman bits
DH_BITS = 512 1024 2048

# List of domains extracted from the domain file
DOMAINS = $(shell cat $(DOMAIN_LIST))

# Do the files
all: PHONY $(FILES) ssl-self-signed-certs

make-tmp: PHONY
	mkdir -p tmp

# Create the mail.yml file for mustache to work
mail.yml:
	echo "---" >mail.yml
	echo "hostname: $(HOST)" >>mail.yml
	echo "fqdn: $(FQDN)" >>mail.yml
	echo "domains:" >>mail.yml
	sed  "s/^/    - /" $(DOMAIN_LIST) >>mail.yml
	echo "people: $(PEOPLE)" >>mail.yml
	echo "group: $(GROUP)" >>mail.yml
	echo "---" >>mail.yml

# Cleanup
clean: PHONY
	rm -rf $(FILES) mail.yml etc/ssl tmp

# Install gems
bundle: PHONY
	bundle install $(BUNDLE)

# Generate files
$(FILES): | bundle
	bundle exec mustache mail.yml $@.mustache >$@

create-groups: PHONY
	# a group for the inhabitants
	groupadd $(GROUP)
	# a group for private keys
	groupadd --system keys

# Create directories
ssl-dirs: PHONY
	# setgid set for private keys
	install -d -m 2750 private
	install -d -m 755 certs

# Generate DH params, needed by Perfect Forward Secrecy cyphersuites
# Some notes:
# * Read this for DH in postfix: http://postfix.1071664.n5.nabble.com/Diffie-Hellman-parameters-td63096.html
# * With certtool 3.3.4 creation of dh params for 4096 bits fail
DIFFIE_HELLMAN_PARAMS = $(addsuffix .dh,$(addprefix private/,$(DH_BITS)))
$(DIFFIE_HELLMAN_PARAMS): private/%.dh: | ssl-dirs
	certtool --generate-dh-params \
	         --outfile private/$*.dh \
	         --bits $*

# Generate all dh params
ssl-dh-params: $(DIFFIE_HELLMAN_PARAMS)

SSL_TEMPLATES = $(addsuffix .cfg,$(addprefix tmp/,$(DOMAINS)))
$(SSL_TEMPLATES): tmp/%.cfg: mail.yml | bundle make-tmp
	sed "s,fqdn: .*,fqdn: $*," mail.yml | bundle exec mustache - certs.cfg.mustache >$@

# Wildcard domains allow to share a single certificate across subdomains
X_SSL_TEMPLATES = $(addsuffix .cfg,$(addprefix tmp/x.,$(DOMAINS)))
$(X_SSL_TEMPLATES): tmp/x.%.cfg: mail.yml | bundle make-tmp
	sed "s,fqdn: .*,fqdn: '*.$*'," mail.yml | bundle exec mustache - certs.cfg.mustache >$@

# Generates the private key for a domain, requires GnuTLS installed
SSL_PRIVATE_KEYS = $(addsuffix .key,$(addprefix private/,$(DOMAINS)))
$(SSL_PRIVATE_KEYS): | ssl-dirs
	certtool --generate-privkey \
	         --outfile $@ \
	         --sec-param $(SECURITY)

# Generates all private keys
ssl-private-keys: $(SSL_PRIVATE_KEYS)
	chown root:keys $(SSL_PRIVATE_KEYS)
	chmod 640 $(SSL_PRIVATE_KEYS)

# Generates a self-signed certificate
# This is enough for a mail server and if you don't want to pay a lot of
# USD for a few thousand bits.  It's not for user agents trying to
# verify your certs unaware of this situation
SSL_SELF_SIGNED_CERTS = $(addsuffix .crt,$(addprefix certs/,$(DOMAINS)))
$(SSL_SELF_SIGNED_CERTS): certs/%.crt: private/%.key tmp/%.cfg
	certtool --generate-self-signed \
	         --outfile $@ \
	         --load-privkey $< \
	         --template tmp/$*.cfg

# Wildcard domains are generated using the same key
X_SSL_SELF_SIGNED_CERTS = $(addsuffix .crt,$(addprefix certs/x.,$(DOMAINS)))
$(X_SSL_SELF_SIGNED_CERTS): certs/x.%.crt: private/%.key tmp/x.%.cfg
	certtool --generate-self-signed \
	         --outfile $@ \
	         --load-privkey $< \
	         --template tmp/x.$*.cfg

# Generates all self signed certs including wildcard
ssl-self-signed-certs: $(SSL_SELF_SIGNED_CERTS) $(X_SSL_SELF_SIGNED_CERTS)
	chown root:root $(SSL_SELF_SIGNED_CERTS) $(X_SSL_SELF_SIGNED_CERTS)
	chmod 644 $(SSL_SELF_SIGNED_CERTS) $(X_SSL_SELF_SIGNED_CERTS)

# First step on the process of getting a certificate, generate a
# request.  This file must be uploaded to the CA.  You can get one for
# free at cacert.org or starssl.com (though they ask for personal info.)
SSL_REQUEST_CERTS = $(addsuffix .csr,$(addprefix private/,$(DOMAINS)))
$(SSL_REQUEST_CERTS): private/%.csr: private/%.key tmp/%.cfg
	certtool --generate-request \
	         --outfile $@ \
	         --load-privkey $< \
	         --template tmp/$*.cfg

X_SSL_REQUEST_CERTS = $(addsuffix .csr,$(addprefix private/x.,$(DOMAINS)))
$(X_SSL_REQUEST_CERTS): private/x.%.csr: private/%.key tmp/x.%.cfg
	certtool --generate-request \
	         --outfile $@ \
	         --load-privkey $< \
	         --template tmp/x.$*.cfg

# Generate all SSL requests
ssl-request-certs: $(SSL_REQUEST_CERTS) $(X_SSL_REQUEST_CERTS)

PHONY:
.PHONY: PHONY
