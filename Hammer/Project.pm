package Hammer::Project;

use strict;
use warnings;

use File::Spec::Functions qw(catdir splitdir);
use Git::Repository;
use Hammer::Project::Status;

#################################
# Git::Repository::Plugin::KK
package Git::Repository::Plugin::KK {
  use Git::Repository::Plugin;
  our @ISA      = qw( Git::Repository::Plugin );
  sub _keywords { qw( rev_parse cat_object merge rebase ) }

  sub rev_parse
  {
    # skip the invocant when invoked as a class method
    return undef if !ref $_[0];
    my $r = shift;
    my $res = $r->run('rev-parse', '--revs-only', @_, { quiet => 1, fatal => [-128 ]});
    return undef unless defined $res;
    return undef unless $res ne '';
    return $res;
  }

  sub cat_object
  {
    # skip the invocant when invoked as a class method
    return undef if !ref $_[0];
    return $_[0]->run('cat-file', '-p', $_[1]);
  }

  sub merge
  {
    my $git = shift;
    my $output = shift;
    my $cmd = $git->command('merge', @_);
    push @$output, $cmd->final_output();
    return $cmd->exit();
  }

  sub rebase
  {
    my $git = shift;
    my $output = shift;
    my $cmd = $git->command('rebase', @_);
    push @$output, $cmd->final_output();
    return $cmd->exit();
  }
}

Git::Repository::Plugin::KK->install();


sub new
{
  my ($class, $hash, %o) = @_;
  $hash->{_stderr} = $o{stderr};
  $hash->{_stdout} = $o{stdout};
  $hash->{_root}   = $o{root};
  bless $hash, $class;
}

## get the absolute base path to the work tree of this project
sub abs_path
{
  my $self = shift;
  my $base = $self->{_root};
  return catdir($base, $self->{path});
}

sub ham_dir_rel
{
  my ($self, $sub, $dir) = @_;
  $sub = $self->{path} unless defined $sub;
  $sub = substr $sub, 1 if substr($sub, 0, 1) eq '/';
  my @d = splitdir($sub);
  $dir = catdir('..', $dir) foreach @d;
  return $dir;
}

## test if the work tree diretory exists
sub exists { return -e $_[0]->abs_path; }

## check forthe existence of the '.git' directory
sub is_git_repo { return -e $_[0]->abs_path.'/.git'; }

## get the Git::Repository object for this project (incl. a work tree)
sub git
{
  my $self = shift;
  my $err = shift;

  return $self->{_repo} if defined $self->{_repo};

  if (not $self->is_git_repo) {
    push @$err, "$self->{path} is not a git repository (.git missing)" if defined $err;
    return undef;
  }

  my $r = $self->{_bare_repo} = $self->{_repo}
        = Git::Repository->new(git_dir => $self->abs_path.'/.git',
                               work_tree => $self->abs_path,
                               { env => { LC_ALL => 'C' } });
  if (not defined $r and defined $err) {
    push @$err, "$self->{path} is not a valid git repository";
    return undef;
  }

  return $r;
}

## get the Git::Repository object for this project (bare)
sub bare_git
{
  my $self = shift;
  my $err = shift;
  return $self->{_bare_repo} if defined $self->{_bare_repo};

  if (not $self->is_git_repo) {
    push @$err, "$self->{path} is not a git repository (.git missing)" if defined $err;
    return undef;
  }

  my $r = $self->{_bare_repo} = Git::Repository->new(git_dir => $self->abs_path.'/.git',
                                                     { env => { LC_ALL => 'C' } });
   if (not defined $r and defined $err) {
    push @$err, "$self->{path} is not a valid git repository";
    return undef;
  }

  return $r;
}


## initialize the project work tree (.git)
sub init
{
  my $self = shift;
  Git::Repository->run( init => $self->abs_path, { env => { LC_ALL => 'C' } } );
  $self->{_bare_repo} = $self->{_repo} = Git::Repository->new(work_tree => $self->abs_path,
                                                              { env => { LC_ALL => 'C' } });
}

sub logerr
{
  my $self = shift;
  push @{$self->{_stderr}}, map { "$self->{path}: $_" } @_;
}

sub loginfo
{
  my $self = shift;
  push @{$self->{_stdout}}, map { "$self->{path}: $_" } @_;
}

sub handle_output
{
  my ($self, $cmd) = @_;

  my @cerr = $cmd->stderr->getlines;
  my @cout = $cmd->stdout->getlines;
  $cmd->close;
  chomp @cout;
  chomp @cerr;
  # log normal output immediately, to see the progress
  print STDOUT "$self->{name}: $_\n" foreach @cout;
  # disabled: logging to buffer and delayed output
  # $self->loginfo(@cout);
  if ($cmd->exit != 0) {
    $self->logerr(@cerr);
  } else {
    $self->loginfo(@cerr);
  }
}

## do a conditional checkout for sync
sub sync_checkout
{
  my ($self, $opts) = @_;
  my $git = $self->git($self->{_stderr});
  return 0 unless defined $git;

  my $head = $git->rev_parse('--abbrev-ref', 'HEAD');

  # return if we have already a valid checkout, don't touch the working copy
  if (defined $head) {

    if ($opts->{rebase}) {
      if ($head ne $self->{revision}) {
        if (defined $opts->{upstream}) {
          $self->checkout($self->{revision});
          $head = $git->rev_parse('--abbrev-ref', 'HEAD');
        } else {
          $self->loginfo("not on branch $self->{revision}, skip rebase");
          return 1;
        }
      }
    } else {
      my $cmd = $self->git->command('pull', '--ff-only', $self->{_remote}->{name}, "$self->{revision}:$self->{revision}", {quiet => 1, fatal => [-128 ]});
      $self->handle_output($cmd);

      return 1;
    }

    my $remote = $self->{_remote}->{name};
    my $remote_ref_n = "refs/remotes/$remote/$head";
    my $remote_ref = $git->rev_parse($remote_ref_n);
    if (not $remote_ref) {
      $self->loginfo("no corresponding remote branch found ($head), skipping rebase");
      return 1;
    }

    $self->handle_output($self->git->command('rebase', $remote_ref_n));
    return 1;
  }

  my $revision = $self->{revision};
  print STDERR "checkout $self->{name} @ $self->{path} ($revision)\n";
  if (not defined $revision) {
    $self->logerr("has no revision to checkout");
    return 0;
  }

  if (not defined $self->{_remote} or not defined $self->{_remote}->{name}) {
    $self->logerr("has no valid remote");
    return 0;
  }

  my $remote_name = $self->{_remote}->{name};
  if (not $git->rev_parse("$remote_name/$revision")) {
    $self->logerr("has no branch named $revision");
    return 0;
  }

  $self->checkout('-b', $revision, '--track', $remote_name.'/'.$revision);
  return 1;
}

## prepare the git repo after sync, incl. checkout
sub prepare
{
  my ($self, $opts) = @_;
  return 0 unless $self->sync_checkout($opts);
  my $git = $self->bare_git;
  if (defined $self->{_remote}->{review} and $self->{_remote}->{review} ne '') {
    my $hooks = $git->git_dir.'/hooks';
    if (not -e "$hooks/commit-msg") {
      make_path($hooks) unless -d $hooks;
      my $base = $self->{_root};
      if (index($hooks, $base) != 0) {
        $self->logerr("$hooks is not within our repo at $base");
        return 0;
      }

      my $rel_hooks = $self->ham_dir_rel(substr($hooks, length($base)),
                                         '.ham/hooks/commit-msg');
      symlink($rel_hooks, "$hooks/commit-msg")
        or $self->logerr("fatal: link $hooks/commit-msg: $!");
    }

    $git->run(config => '--bool', 'gerrit.createChangeId', 'true');
  } else {
    $git->run(config => '--bool', 'gerrit.createChangeId', 'false');
  }
  return 1;
}

my $trace = 0;

sub _fetch_progress
{
  local $_ = shift;
  my $self = shift;
  s|\n||gm;
  if ($_ ne '' and $self->{trace_fetch} or $trace) {
    print STDERR "$self->{name}: $_\n";
    $self->logerr($_);
  } elsif (/^fatal:|^ssh:/) {
    $self->{trace_fetch} = 1;
    print STDERR "$self->{name}: $_\n";
    $self->logerr($_);
  }

  if (/^remote: Finding sources:\s*([0-9]+%).*$/) {
    return "$self->{name}: $1";
  } elsif (/^Receiving object:\s*([0-9]+%).*$/) {
    return "$self->{name}: $1";
  } elsif (/^Resolving deltas:\s*([0-9]+%).*$/) {
    return "$self->{name}: $1";
  }
  return undef;
}

sub _collect
{
  local $_ = shift;
  my $self = shift;
  push @{$self->{output}}, $_;
}

sub fetch
{
  my $self = shift;
  return (
    $self->bare_git->command('fetch', '--progress', @_, { quiet => 1 }),
    out => \&_collect, err => \&_fetch_progress, args => $self,
    finish => sub {
      $self->{trace_fetch} = 0;
      return "done fetching $self->{name}"
    }
  );
}

## checkout the work tree
sub checkout
{
  my $r = shift;
  my @args = @_;
  my $branch = \(grep { not /^-/ } @args)[0];
  $$branch =~ s,\{UPSTREAM\},$r->{revision},g;

  my $git = $r->git;
  if (not $git) {
    $r->logerr("is no git repo (may be you need 'sync')");
    return 128;
  }

  my $head = $git->rev_parse('--abbrev-ref', 'HEAD');
  return if defined $head and $head eq $$branch;
  $head = '' unless defined $head;

  my $cmd = $git->command('checkout', @args, '--', {fatal => [-128], quiet => 1});
  my @cerr = $cmd->stderr->getlines;

  if (grep /invalid reference: $$branch/, @cerr) {
    $r->loginfo("has no reference $$branch, stay at the previous head ($head)");
    return 128;
  }
  if (grep /(Already on )|(Switched to branch )'$$branch'/, @cerr) {
    return 128;
  }

  if (grep /Switched to a new branch /, @cerr) {
    # this happens for the initial checkout of a remote branch
    return 128;
  }

  if (@cerr) {
    chomp(@cerr);
    $r->logerr(@cerr);
  }
  return $cmd->exit;
}

## sync #############################################
sub sync
{
  my $self = shift;
  my $remote_name = $self->{_remote}->{name};
  my $r;
  ::make_path($self->abs_path) unless $self->exists;
  if ($self->is_git_repo) {
    $r = $self->bare_git;
    #print STDERR "fetch $self->{name} from $remote_name\n";
    return $self->fetch($remote_name);
  } else {
    #print "run: ($self->{path}) git clone $remote_name\n";
    my $url = $self->{_remote}->{fetch};

    my($scheme, $authority, $path, $query, $fragment) =
      $url =~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;

    $path = "" unless defined $path;
    $query = "" unless defined $query;
    $fragment = "" unless defined $fragment;

    if ($self->{name} ne '') {
      $url = "$scheme://$authority$path/$self->{name}$query$fragment";
    }
    $r = $self->init;
    $r->run('remote', 'add', $remote_name, $url);
    return $self->fetch($remote_name);
  }
}


sub status
{
  my $self = shift;
  my $r = $self->git($self->{_stderr});
  return unless $r;
  return Hammer::Project::Status->new($r->run(status => '--porcelain', '-b'));
}

sub print_status
{
  my $self = shift;
  my $s = $self->status;
  if ($s->is_different or $s->is_dirty) {
    print "project: $self->{name} at ".$self->abs_path."\n";
    print join("\n", @$s)."\n";
  }
  return;
}


sub check_rev_list
{
  my ($prj, $r, $src_br, $rev_list) = @_;

  my @no_chid = ();
  my %duplicate_chid = ();
  my @duplicate_chid = ();
  my @multiple_chid = ();

  foreach my $c (@$rev_list) {
    my @cmt = $r->cat_object($c);
    my @chid = grep /^Change-Id:/, @cmt;
    if (not @chid) {
      push @no_chid, $c;
      next;
    } elsif (scalar(@chid) > 1) {
      push @multiple_chid, $c;
      next;
    }

    my $chid = $chid[0];
    $chid =~ s/^Change-Id:\s*(\S+)/$1/;

    if ($chid eq '') {
      push @no_chid, $c;
      next;
    }

    if ($duplicate_chid{$chid}) {
      push @{$duplicate_chid{$chid}}, $c;
      push @duplicate_chid, $chid;
      next;
    } else {
      $duplicate_chid{$chid} = [ $c ];
    }
  }

  my $list_errors = sub
  {
    my ($msg, $e) = @_;
    return unless @$e;
    $prj->logerr("branch $src_br: $msg");
    foreach my $c (@$e) {
      my $x = $r->run('log', '-n', '1' ,'--oneline', '--color=always', $c);
      $prj->logerr("  $x");
    }
  };

  $list_errors->("the following commits have no change ID", \@no_chid);
  $list_errors->("the following commits have multiple chage IDs", \@multiple_chid);
  foreach my $id (@duplicate_chid) {
    $list_errors->("the following commits have the same change ID (you should squash them)",
                   $duplicate_chid{$id});
  }

  return 0 if @no_chid or @multiple_chid or @duplicate_chid;
  return 1;
}

sub check_for_upload
{
  my ($prj, $warn, $src_br, $dst_br, $approve_cb) = @_;
  my $r = $prj->git($prj->{_stderr});
  my $src_rev = $r->rev_parse($src_br);

  if (not $src_rev) {
    push @$warn, "$prj->{path}: branch has no branch $src_br, skipping.";
    return 0;
  }

  my $remote = $prj->{remote};
  $dst_br = $prj->{revision} unless defined $dst_br;
  my $rem_br = "$remote/$dst_br";
  my $dst_rev = $r->rev_parse($rem_br);

  if (not $dst_rev) {
    push @$warn, "$prj->{path}: branch has no branch $remote/$dst_br, skipping.";
    return 0;
  }

  # skip if there is nothing to do
  return 0 if $src_rev eq $dst_rev;

  my $merge_base = $r->run('merge-base', $dst_rev, $src_rev);
  if (!$merge_base) {
    $prj->logerr("$src_br is not derived from $rem_br");
    return 0;
  }

  my @commits = $r->run('rev-list', '--ancestry-path', "^$merge_base", $src_rev);
  if (not @commits) {
    $prj->logerr("$src_br is not derived from $rem_br");
    return 0;
  }

  # check if all commits have change IDs
  return 0 unless $prj->check_rev_list($r, $src_br, \@commits);

  # check the number of changes for this branch
  my $num_changes = scalar(@commits);
  if ($num_changes > 1) {
    if (not defined $approve_cb or not $approve_cb->($prj, \@commits)) {
      $prj->logerr("branch $src_br has more than one ($num_changes) change for $rem_br");
      return 0;
    }
  }
  return wantarray ? (1, $src_br, $dst_br) : 1;
}

1;
