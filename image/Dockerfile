FROM ubuntu-debootstrap:14.04
MAINTAINER Greg Osuri <greg@overclock.io>

ENV DEBIAN_FRONTEND noninteractive
ENV LC_ALL C
ENV RAILS_ENV test
ENV RACK_ENV test
ENV RUBY_VERSION 2.1.2
ENV NODE_VERSION 0.10.33
ENV PATH /app/bin:/app/vendor/bundle/bin:/app/vendor/ruby/${RUBY_VERSION}/bin:/app/vendor/node/${NODE_VERSION}/bin:${PATH}

ADD ./bootstrap /tmp/bootstrap
RUN bash /tmp/bootstrap
