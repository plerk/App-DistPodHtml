package App::DistPodHtml::XHTML;

use strict;
use warnings;
use v5.10;
use base qw( Pod::Simple::XHTML );

sub new
{
  my $class = shift;
  my %args = @_;
  my $resolver = delete $args{resolver};
  my $self = $class->SUPER::new(%args);
  $self->html_header('');
  $self->html_footer('');
  $self->html_h_level(3);
  $self->{_app_distpodhtml} = {
    resolver => $resolver
  };
  return $self;
}

sub resolve_pod_page_link
{
  my $self = shift;
  my($page) = @_;
  return $self->SUPER::resolve_pod_page_link(@_) unless defined $page;
  my $url = $self->{_app_distpodhtml}->{resolver}->($page) // $self->SUPER::resolve_pod_page_link(@_);
  return $url;
}

1;
