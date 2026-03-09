FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's|http://archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ruby ruby-dev build-essential ca-certificates \
    && gem install fluentd --no-document \
    && gem install bundler --no-document \
    && fluentd --setup /fluentd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /fluentd/plugins/fluent-plugin-oceanbase-logs

COPY Gemfile fluent-plugin-oceanbase-logs.gemspec ./
COPY lib/ lib/

RUN gem build fluent-plugin-oceanbase-logs.gemspec \
    && gem install fluent-plugin-oceanbase-logs-*.gem --no-document

COPY example/ example/

CMD ["fluentd", "-c", "/fluentd/etc/example/fluentd.conf"]
