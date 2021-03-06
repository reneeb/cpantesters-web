FROM cpantesters/schema
RUN curl -sL https://deb.nodesource.com/setup_12.x | bash - && \
    apt-get install -y nodejs
# Load some modules that will always be required, to cut down on docker
# rebuild time
RUN cpanm -v \
    CSS::Minifier::XS \
    JavaScript::Minifier::XS \
    Mojolicious \
    Mojolicious::Plugin::OAuth2 \
    Mojolicious::Plugin::AssetPack \
    Mojolicious::Plugin::Yancy
# Load last version's modules, to again cut down on rebuild time
COPY ./cpanfile /app/cpanfile
RUN cpanm --installdeps .

COPY ./ /app
RUN dzil authordeps --missing | cpanm -v --notest
RUN dzil listdeps --missing | cpanm -v --notest
RUN cd share && npm install
RUN dzil install --install-command "cpanm -v ."

COPY ./etc/docker/web/my.cnf /root/.cpanstats.cnf
COPY ./etc/docker/web/web.development.conf /app
ENV MOJO_HOME=/app
CMD [ "cpantesters-web", "daemon" ]
EXPOSE 3000
VOLUME /app
