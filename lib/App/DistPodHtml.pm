package App::DistPodHtml;

use strict;
use warnings;
use v5.10;
use Path::Class qw( file dir );
use URI::file;
use File::HomeDir;
use JSON qw( decode_json );
use Template;
use File::Copy qw( copy );
use App::DistPodHtml::XHTML;
use LWP::UserAgent;
use YAML::XS qw( LoadFile DumpFile );

# ABSTRACT: Generate HTML of Perl POD
# VERSION

my $tt = Template->new(
  INCLUDE_PATH => __PACKAGE__->share_dir->subdir('tt'),
);
my $ua = LWP::UserAgent->new;

sub main
{
  my $dists = prune_dists(find_dists(dir(File::HomeDir->my_home, 'dev')));
  my $pods  = index_dists($dists);
  my $dest = dir(File::HomeDir->my_home, 'public_html');

  my $vars = { 
    description => 'Pod Documentation',
    author      => 'Unknown',
    favicon     => 'http://perl.com/favicon.ico',
    brand       => 'Perl Documentation',
    home_url    => URI::file->new($dest->file('index.html')),
  };
  
  copy_support_files($dest, $vars);
  prep_output_tree($dest, $dists, $pods, $vars, $tt);
  generate_html($dest, $pods, $vars, $tt);
}

my $cache = eval { LoadFile("/tmp/.app_distpodhtml.yml") } // {};
END {
  delete $cache->{$_} for grep { ! $cache->{$_} } keys %$cache;
  DumpFile("/tmp/.app_distpodhtml.yml", $cache);
};

sub verify_link
{
  my $url = shift;

  unless(defined $cache->{$url})
  {
    #say "try $url";
    my $response = $ua->get($url);
    $cache->{$url} = $response->is_success;
  }
  
  return $cache->{$url};
}

sub generate_html
{
  my($dir, $pods, $vars, $tt) = @_;

  my $name;
  my $pod;

  my $resolver = sub {
    my($page) = @_;
    return $pods->{$page}->{url} if defined $pods->{$page};
    my $url = "https://metacpan.org/module/" . $page;
    return $url if verify_link($url);    
    say STDERR "BAD LINK $name => $page";
    return;
  };

  while(($name, $pod) = each %$pods)
  {
    my $psx = App::DistPodHtml::XHTML->new( resolver => $resolver );
    local $vars->{pod_html} = '';
    local $vars->{pod} = { name => $name, %$pod };
    local $vars->{pl} = $pod->{file}->slurp;
    $psx->output_string(\$vars->{pod_html});
    $psx->parse_file($pod->{file}->stringify);
    $pod->{html}->spew(do {
      my $html = '';
      $tt->process('pod.tt', $vars, \$html) || die $tt->error;
      $html;
    });
  }  
}

sub copy_support_files
{
  my($dir, $vars) = @_;
  foreach my $type (qw( css img js ))
  {
    my $to = $dir->subdir($type);
    $to->mkpath(0,0755);
    copy($_, $to->file($_->basename)) foreach __PACKAGE__->share_dir->subdir($type)->children(no_hidden => 1);
    # TODO when using file: urls maybe just point to the share_dir
    $vars->{$type . '_url'} = URI::file->new($to);
  }
}

sub prep_output_tree
{
  my($dir, $dists, $pods, $vars, $tt) = @_;
  $dir->mkpath(0,0755); # in case it doesn't already exist
  
  local $vars->{dists} = [];
  
  while(my($name,$dist) = each %$dists)  
  {
    $dir->subdir($name)->mkpath(0,0755);
    push @{ $vars->{dists} }, { 
      name => $name, 
      url  => URI::file->new($dir->file($name, 'index.html')),
      meta => $dist->{meta},
     };

    local $vars->{pods} = [];
    while(my($podname, $file) = each %{ $dist->{docs} })
    {
      my $html = $dir->file($name, "$podname.html");
      my $url = URI::file->new($html);
      push @{ $vars->{pods} }, { name => $podname, url => $url };
      $pods->{$podname}->{url}  = $url;
      $pods->{$podname}->{html} = $html;
    }

    @{ $vars->{pods} } = sort { lc $a->{name} cmp lc $b->{name} } @{ $vars->{pods} };

    local $vars->{dist} = $dist;

    $dir->file($name, 'index.html')->spew(do {
      my $html = '';
      $tt->process('dist_index.tt', $vars, \$html) || die $tt->error;
      $html;
    });
  }

  @{ $vars->{dists} } = sort { lc $a->{name} cmp lc $b->{name} } @{ $vars->{dists} };
  
  $dir->file('index.html')->spew(do {
      my $html = '';
      $tt->process('dists_index.tt', $vars, \$html) || die $tt->error;
      $html;
  });
}

# find all build distributions under the given directory
sub find_dists
{
  my($dir) = @_;
  if(-e $dir->file('META.json'))
  {
    return [ { dir => $dir, meta => decode_json( $dir->file('META.json')->slurp ) } ];
  }
  else
  {
    my @list;
    foreach my $subdir (grep { $_->is_dir } $dir->children(no_hidden => 1))
    {
      push @list, @{ find_dists($subdir) };
    }
    return \@list;
  }
}

# prune out old versions and return a hash Dist-Name => { meta => {}, dir => Path::Class::Dir }
sub prune_dists
{
  my($dists) = @_;
  
  my %dists;
  
  foreach my $dist (@$dists)
  {
    my $dir = $dist->{dir};
    my $name = $dist->{meta}->{name};
    my $version = $dist->{meta}->{version};
    die "no name or version: $dir" unless defined $name && defined $version;
    if(defined $dists{$name})
    {
      if($version > $dists{$name}->{meta}->{version})
      {
        $dists{$name} = $dist;
      }
    }
    else
    {
      $dists{$name} = $dist;
    }
  }
  
  return \%dists;
}

# find the scripts, .pm and .pod files in the dist for indexing
# returns hash of PodName => { dist => { meta => {}, dir => Path::Class::Dir }, file => Path::Class::File }
# adds to each dist { docs => { PodName => Path::Class::File } }
sub index_dists
{
  my($dists) = @_;
  
  my %pod;
  
  foreach my $dist (values %$dists)
  {

    my $add = sub {
      my($podname, $file) = @_;
      die "duplicate for $podname: $file and " . $pod{$podname}->{file}
        if defined $pod{$podname};
      $pod{$podname} = { dist => $dist, file => $file };
      $dist->{docs}->{$podname} = $file;
    };

    my $dir = $dist->{dir};
    if(-d $dir->subdir('bin'))
    {
      foreach my $script ($dir->subdir('bin')->children(no_hidden => 1))
      {
        $add->($script->basename, $script);
      }
    }
    
    my $recurse;
    $recurse = sub {
      my($dir, @name) = @_;
      foreach my $child ($dir->children(no_hidden => 1))
      {
        if($child->is_dir)
        { $recurse->($child, @name, $child->basename) }
        elsif($child->basename =~ /^(.*)\.(pod|pm)$/)
        { $add->(join('::', @name, $1), $child ) }
      }
    };
    
    if(-d $dir->subdir('lib'))
    {
      $recurse->($dir->subdir('lib'));
    }
  }
  
  \%pod;
}

sub share_dir
{
  state $path;

  unless(defined $path)
  {
    # if $VERSION is not defind then we've added the lib
    # directory to PERL5LIB, and we should find the share
    # directory relative to the DistPodHtml.pm module which is
    # still in its dist.  Otherwise, we can use File::ShareDir
    # to find the distributions share directory for this
    # distribution.
    if(defined $App::DistPodHtml::VERSION)
    {
      # prod
      $path = Path::Class::Dir
        ->new(dist_dir('App-DistPodHtml'));
    }
    else
    {
      # dev
      $path = Path::Class::File
        ->new($INC{'App/DistPodHtml.pm'})
        ->absolute
        ->dir
        ->parent
        ->parent
        ->subdir('public');
    }
  }
  
  $path;
}

1;
