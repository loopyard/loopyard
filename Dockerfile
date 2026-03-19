FROM ruby:3.2-slim

RUN gem install sinatra rackup puma webrick

WORKDIR /app
COPY app.rb .

EXPOSE 3000

CMD ["ruby", "app.rb"]
