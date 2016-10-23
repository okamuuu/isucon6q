package MyProfiler;

use strict;
use warnings;
use utf8;
use Carp();
use Data::Dumper;
use Time::HiRes;

sub new {
    my ($class, %args) = @_;

    bless {
        times_of => {},
        measuring_times => {},
    }, $class;
}

sub start {
  my ($self, $key) = @_;

  if ($self->{measuring_times}->{$key}) {
    Carp::croak("Error: " . $key . ' should be removed before start');
  }

  my $start = Time::HiRes::time;
  $self->{measuring_times}->{$key} = $start;
}

sub end {
  my ($self, $key) = @_;
  if (not $self->{times_of}->{$key}) {
    $self->{times_of}->{$key} = 0;
  }

  my $start = delete $self->{measuring_times}->{$key};
  $self->{times_of}->{$key} += Time::HiRes::time - $start;
}

sub debug {
  my ($self) = @_;
  return $self->{times_of};
}

sub DESTROY {
  my ($self) = @_;
  if (scalar keys %{$self->{measuring_times}}) {
    warn '=' x 50;
    warn "Error: Some keys weren't called end()";
    warn Dumper keys %{$self->{measuring_times}};
  }
  warn Dumper $self->debug();
}

our $VERSION = 0.01;

1;

