ARG RUBY_VERSION=3.4.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY infra/ infra/
COPY domains/ domains/
COPY apps/rails_application/Gemfile apps/rails_application/Gemfile.lock apps/rails_application/

WORKDIR /app/apps/rails_application
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

WORKDIR /app
COPY apps/rails_application/ apps/rails_application/

WORKDIR /app/apps/rails_application
RUN bundle exec bootsnap precompile --gemfile && \
    bundle exec bootsnap precompile app/ lib/

RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /app /app

WORKDIR /app/apps/rails_application

RUN mkdir -p db log storage tmp

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
