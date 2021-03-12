FROM ruby:3.0
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev nodejs less

RUN gem install bundler -v '2.1.4'

RUN wget http://www.freetds.org/files/stable/freetds-1.1.24.tar.gz
RUN tar -xzf freetds-1.1.24.tar.gz
RUN cd freetds-1.1.24 && ./configure --prefix=/usr/local #--with-tdsver=7.2
RUN cd freetds-1.1.24 && make
RUN cd freetds-1.1.24 && make install

RUN mkdir /app
WORKDIR /app
COPY ./app /app
