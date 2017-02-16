#!/usr/bin/env perl

use Mojo::RabbitMQ::Client;
use DateTime;
use DateTimeX::Start qw( start_of_date );
use JSON;

sub get_seconds_since_start_of_day {
   my $now = shift;
   # There are days that don't have 00:00:00, or have it twice a day
   # start_of_date() handles that correctly.
   my $start = start_of_date($now);
   return $now->epoch - $start->epoch;
}
 
sub get_seconds_total_today {
  my $now = shift;
  my $std = 86400;
  my $ret = $std;
 
  # Daylight saving
  my $today = $now->truncate(to => "day");
  my $tomorrow = $today->add(days => 1);
  if($today->is_dst && !$tomorrow->is_dst) {
    $ret += 3600; # Our day has 25 hours today
  } elsif(!$today->is_dst && $tomorrow->is_dst) {
    $ret -= 3600; # Our day has 23 hours today
  }
 
  # Leap seconds
  $ret += ($tomorrow->leap_seconds - $today->leap_seconds);
  return $ret;
}

my $client = Mojo::RabbitMQ::Client->new(url => 'amqp://guest:guest@127.0.0.1:5672/');
# Catch all client related errors
$client->catch(sub { warn "Some error caught in client"; });

# When connection is in Open state, open new channel
$client->on(
  open => sub {
    my ($client) = @_;
 
    # Create a new channel with auto-assigned id
    my $channel = Mojo::RabbitMQ::Client::Channel->new();
 
    $channel->catch(sub { warn "Error on channel received"; });
 
    $channel->on(
      open => sub {
        my ($channel) = @_;
        $channel->qos(prefetch_count => 1)->deliver;

        # Start consuming messages from test_queue
        my $consumer = $channel->consume(queue => 'test_queue');
        $consumer->on(
          message => sub {
            my ($message) = @_;
            print "Got a message:\n";
            print $message->{body} . "\n";
            my $body = from_json $message->{body};
            if($body->{msg} =~ m/tagometer/i) {
              my $now = DateTime->now(time_zone => 'Europe/Berlin');
              my $percent = (get_seconds_since_start_of_day($now) / get_seconds_total_today($now)) * 100;
              my $routing_key = $message->{routing_key};
              my $result = to_json {
                msg  => $percent,
                nick => '???',
                jid  => '???'
              };
              my $publish = $channel->publish(
                exchange    => 'test',
                routing_key => $routing_key,
                body        => $result,
                mandatory   => 0,
                immediate   => 0,
                header      => {}
              );
              # Deliver this message to server
              $publish->deliver;
            }
          }
        );
        $consumer->deliver;
      }
    );
    $channel->on(close => sub { warn 'Channel closed' });
    $client->open_channel($channel);
  }
);
 
# Start connection
$client->connect();
 
# Start Mojo::IOLoop if not running already
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
