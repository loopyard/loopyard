require 'sinatra'

set :port, 3000
set :bind, '0.0.0.0'

GREETINGS = [
  "Hello there, stranger!",
  "Hey! Welcome aboard!",
  "Howdy, partner!",
  "Greetings, Earthling!",
  "Yo! What's up?",
  "Ahoy, matey!",
  "Bonjour, mon ami!",
  "Hola, amigo!",
  "Top of the morning to ya!",
  "Well hello, fancy seeing you here!"
]

get '/' do
  GREETINGS.sample
end
