FROM ubuntu-debootstrap:14.04
MAINTAINER Greg Osuri <greg@overclock.io>

ENV DEBIAN_FRONTEND noninteractive
ENV LC_ALL C
ENV RAILS_ENV test
ENV RACK_ENV test
ENV NODE_VERSION 0.10.33
ENV PATH /app/bin:/app/vendor/bundle/bin:/usr/lib/ruby/bin:/app/vendor/node/${NODE_VERSION}/bin:${PATH}

ADD ./bootstrap /bootstrap
CMD bash /bootstrap
