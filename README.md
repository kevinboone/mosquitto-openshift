# mosquitto-openshift

This repository demonstrates one way to create a Docker image for the
Mosquitto MQTT message broker, and one way to instantiate it as a pod
on OpenShift. The procedure should work with OpenShift 4.x and OpenShift 3.11.

In this document I describe building and testing the container images
using `podman`, but `docker` and `buildah` should work without changes.

This document only describes the installation steps; for a more 
detailed discussion see

http://kevinboone.me/mosquitto-openshift.html

## Mosquitto

Mosquitto is a very lightweight, very simple message broker that supports
on MQTT. As well as the broker, Mosquitto provides a couple of 
command-line utilities that can be used to send and receive messages using
MQTT -- these will be used to test the installation.

Note: I'm assuming that there's a local installation of Mosquitto, or at
least of its command-line clients, that can be used to test the OpenShift
installation. 

Mosquitto can be built so as to support TLS encryption, which will be essential
if it is to be used with the OpenShift router.


## Assumptions

Mosquitto does not support clustering, so there's no reason to run multiple
pods for the same set of clients.

The MQTT broker will need to be accessible from both inside and outside
the OpenShift cluster, so it will have both plaintext and TLS-encrypted
listeners. The TLS listener will be used by the OpenShift router, because 
the router is unable to route MQTT unless it is encrypted.

## The image

The Docker image is based on the minimal Alpine Linux base image, 
giving a final image less than 7Mb in size.

At the time of writing, the latest Alpine release is 3.12. The corresponding
Alpine repository doesn't have a package for Mosquitto so, to simplify the
image build, I'm specifying Alpine 3.11. To use a later Alpine -- if the
package is not present -- you'd need to build it from source. 

To form a practical implementation, the image must provide

- At least one authenticated user -- the default open access is probably not appropriate here. In this source, the user account is `admin` with password `admin` but, of course, this can easily be changed.
- TLS certificates; although the administrator will almost certainly want to replace them with site-specific certificates, the image should provide defaults for testing purposes. 
- A configuration file that specifies (at least) the certificates and port configuration
- A start-up script that runs `mosquitto` with the specified configuration

In this example, all files that are not part of the stock `mosquitto` 
package are in the `files/` directory in this source, and will be copied
into the `/myuser/` directory when the image is built. This is purely for
the convenience of the OpenShift installer -- it helps if all the files
the installer is likely to change are in the same place.

### User credentials file

`mosquitto` provides a simple user/password authentication mechanism, and
also a client certificate authentication mechanism. This example uses only
user/password. The user credentials file is in a proprietary format, and
`mosquitto` provides a utility `mosquitto_passwd` for editing it.

To provide an alternative credentials file, replace the default one as
follows:

    rm files/passwd
    touch files/passwd
    mosquitto_passwd -b files/passwd my_user my_passwd

It's possible to create multiple users with different privileges -- this
requires editing the main configuration file in addition to adding users
to the credentials file.

### Certificate files

Mosquitto requires at least three certificates -- at least in a practical installation.

- A root CA certificate against which all the others will be authenticated. In this example this is named `ca.crt`. This is the certificate that will have to
be shared with clients. I'm generating this file in the example but, in a practical installation it might be a trusted certificate from a commercial CA.

- A server certificate, authenticated by the CA. This will be called `server.crt`

- The primary key certificate corresponding to the server certificate. This will be called `server.key`. 

All these certificates must be in PEM format. 

For the record, these are the commands that generated the certificates in the sample. You might want to use these commands to bake different certificates into
the image, although I would envisage the files being overridden in OpenShift
at installation time, from a secret or configmap (see below).

    $ openssl req -new -x509 -days 3650 -extensions v3_ca -keyout files/ca.key -out files/ca.crt -subj "/O=acme/CN=com"

    $ openssl genrsa -out files/server.key 2048

    $ openssl req -new -out files/server.csr -key  files/server.key -subj "/O=acme2/CN=com"

    $ openssl x509 -req -in files/server.csr -CA files/ca.crt -CAkey files/ca.key -CAcreateserial -out files/server.crt -days 3650

    $ openssl rsa -in files/server.key -out files/server.key

    $ rm files/ca.key files/ca.srl files/server.csr

    $ chmod 644 files/server.key

### Configuration file

The configuration file `mosquitto.conf` identifies the TLS certificates,
and defines two listeners -- a plaintext listener on port 1883, and a TLS
listener on port 8883. These ports are widely used with MQTT.

## Building the image

    podman build .

## Testing locally

Before installing on OpenShift, it might be worth trying the installation.
Get the image ID of the build using `podman image list` then

    $ podman run -it -port 1883:1883 -p 8883:8883  <image> 

This command exposes the plaintext and TLS ports. To test, use
`moquitto_pub` or `mosquitto_sub` to send or receive messages. To
test the plaintext listener:

    $ mosquitto_pub -t foo -m "text" -u admin -P admin

The hostname and port default to `localhost` and 1883, which are appropriate
in this case. To test the TLS listener:

    $ mosquitto_pub -t foo -m "text" --cafile files/ca.crt --insecure -u admin -P admin

Again, the defaults for host and port will be appropriate. You'll need 
the `--insecure` switch to override certificate hostname checks -- the
server certificate in the image has hostname `acme.com`. 

## Publishing the image

If the image works adequately locally, you'll need to publish it to a 
repository from which OpenShift can download it. The various procedures
for doing this are outside the scope of this description. I've published
my image to quay.io, using the following `podman` procedure. 

    $ podman tag <image-id> mosquitto-ephemeral:0.1a
    $ podman login quay.io...
    $ podman push mosquitto-ephemeral:0.1a quay.io/kboone/mosquitto-ephemeral

However the image is published, you'll need a repository URI for OpenShift.
With the quay.io repository, that URI will be:

   quay.io/kboone/mosquitto-ephemeral:latest

## Deploying the image on OpenShift

The most broadly-compatible way to deploy the image is probably to use
a deployment configuration, in YAML format. The steps below should work
without changes on any OpenShift version.

### Deploying a default image on OpenShift

$ oc apply -f mosquitto-ephemeral.yaml

This deploys the image with exposed ports 1883 and 8883, the pre-created
certificates, and a credentials file for the single 'admin' user.

To use this pod from outside the OpenShift cluster, you'll need to create
a route that binds to the TLS port. For example:

    $ oc create route passthrough --service=mosquitto-ephemeral-tls \
             --port 8883 --hostname=mosquitto.apps.my_domain

Note that the chosen hostname must be something that your DNS configuration
will actually connect to the OpenShift router, and the client must connect
using that exact name.

To test the external client, you'll need to get the CA certificate from
the running pod. If you have the source, you already have the CA
certificate -- it's in `files/ca.crt`. Otherwise you can copy it from
the running pod:

    $ oc cp mosquitto-ephemeral-1-<XXXX>:/myuser/ca.crt mosquitto_ca.crt 

Then to test a client outside of OpenShift, invoke the TLS listener
via the OpenShift router:

    $ mosquitto_pub -t foo -m "text" --cafile mosquitto_ca.crt \
         --insecure -u admin -P admin 
	 --host mosquitto.apps.my_domain --port 443

Notice that the `port` here is the router's TLS port, which doesn't correspond
to the TLS port exposed by the running pod. 

### Overriding configuration files OpenShift

I'll demonstrate how to deploy on OpenShift such that a new credentials
file is provided. The file will be supplied in a configmap, and then
the deployment configuration will mount the file from the configmap
on top of the existing `/myuser/passwd`.

Create a new credentials file with a new passwd:

    $ touch passwd
    $ mosquitto_passwd -b passwd foo foo 

This credential file defines a single user `foo` with password `foo`. 

Create a configmap called `passwd` from the file `passwd`:

    $ oc create configmap passwd --from-file=passwd=./passwd

Now we need to modify the deployment configuration YAML to 
mount the new `passwd` file over the one provided in the image.
The modified YAML is in `mosquitto-ephemeral-passwd.yaml`, but the 
relevant configuration is this:

   spec:
     containers:
        volumeMounts:
	  - name: passwd-mount
	    mountPath: /myuser/passwd
	    subPath: passwd

    volumes:
      - name: passwd-mount
        configMap:
	  name: passwd
	  items:
	    - key: passwd
	      path: passwd


Then 

    $ oc apply -f mosquitto-ephemeral-passwd.yaml

You should be able to test the broker as described earlier, and verify
that the new credentials are accepted.

## Further work

In practice, you'll probably need to supply new versions of files in
the `/myuser` directory, including the certificates. The procedure is
exactly the same as I described above for the `passwd` file.

There are various ways in which the configuration might be centralized,
to make installation easier. For example, it might be useful to 
place all the main configuration elements into the YAML deployment descriptor,
rather than in separate files. OpenShift allows this to be done using
environment variables. The values of the variables are set in the 
YAML, and then the start-up script would read the environment variables,
and construct configuration files from them. It's possible, in principle,
to embed entire configuration files into YAML environment variables.

If you adopt such an approach, it's probably advisable to have useful
defaults, in case the deployer does not specify any configuration.

Most deployment on OpenShift is heading towards the use of operators. 
However, there doesn't seem to be anything much to be gained by using 
operators for such a simple deployment. 



