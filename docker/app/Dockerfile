FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install --no-install-recommends -y \
        build-essential \
        libpq-dev \
        libyaml-dev \
        git \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bundle in its own layer so a Gemfile-only change doesn't invalidate the app copy below.
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local path "/usr/local/bundle" \
    && bundle install --jobs "$(nproc)" --retry 3

COPY . .

# Non-root user matching the host developer's uid/gid so bind-mounted files
# stay editable on the host and nothing runs as root.
ARG UID=1000
ARG GID=1000
RUN groupadd -g "${GID}" rails \
    && useradd -u "${UID}" -g rails -m rails \
    && chown -R rails:rails /app /usr/local/bundle

USER rails

# No EXPOSE / no server: this app has no HTTP surface. The default command is a
# shell; real work runs as rake tasks (see docker-compose.yml).
CMD ["sleep", "infinity"]
