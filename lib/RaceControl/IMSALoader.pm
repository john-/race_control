package IMSALoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;

use HTML::Clean;
use HTML::TableExtract;
use Data::Dumper;
use POE::Component::Logger;

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    return $self;
}

sub get_state {
    my ($self, $contents) = @_;
    
    #my $contents = $self->_get_contents();

    my $h = new HTML::Clean(\$contents);

    $h->strip();
    my $data = $h->data();

    my $html = $$data;

    $html =~ s/\n//g;

    # headers which determine what table is extracted
    my @headers = ('Pos', 'Car', 'Cls', 'CP', 'Driver', 'Now', 'Laps', 'Gap', 'Intv', 'LastLap', 'BestLap', 'BestSpeed', 'Best Lap #', 'TotalTime' );

    # what is used for the hash labels. This should be passed to this object
    @hashkeys = qw(position car class class_pos driver status laps gap interval last_lap best_lap best_speed bl_num total_time_last_lap);

    my $te_pos = HTML::TableExtract->new( depth => 1, count => 1 );

    $te_pos->parse($html);
    #Logger->log(Dumper($te_pos));

    unless ($te_pos->tables()) { return }; # there may be other tables, if I cared.

    #Logger->log(Dumper($te_pos->rows));

    my %session = ();

    # made anonymous because of error explained here:
    # http://www.perl.com/pub/a/2002/05/07/mod_perl.html
    my $sub_ref = sub {
        my $row = shift;
        return { map { $hashkeys[$_] => $row->[$_] } (0 .. $#$row) };

    };
    @{$session{positions}} = map { &$sub_ref($_) } $te_pos->rows;
    shift @{$session{positions}};   # first row is header info

    #Logger->log(Dumper(@{$session{positions}}));

    my $cnt = 0;
    foreach (@{$session{positions}}) {
	# these drivers didn't start in session
	if ($_->{position} eq '---') { delete $session{positions}->[$cnt] }

	$_->{position} = $cnt+1; # position numbers are flakey from site
	
        $_->{driver} =~ s/ ?\(.*\)$//; # I don't care if rookie or J.

	if (! defined($_->{status})) { $_->{status} = '' };

        # convert time from MM:SS to seconds
        $_->{last_lap} = RaceControl::Utils::time_to_dec($_->{last_lap});
        $_->{best_lap} = RaceControl::Utils::time_to_dec($_->{best_lap});

	$_->{id} = $_->{car};

	$cnt++;
    }

    my $te_race = HTML::TableExtract->new( depth => 0, count => 1 );
    $te_race->parse($html);

    unless ($te_race->tables()) { return }; # there may be other tables, if I cared.

    ($session{time}) = $te_race->rows->[0][0] =~ /.*: (.*)/;
    ($session{flag}) = $te_race->rows->[0][1] =~ /.*: (\S*)/;
    #($session{control_message}) = $te_race->rows->[0][2] =~ /.*: (.*)/;

    #Logger->log(Dumper($te_race->rows));

    my $te_rm = HTML::TableExtract->new( depth => 1, count => 2 );
    $te_rm->parse($html);

    unless ($te_rm->tables()) { return }; # there may be other tables, if I cared.

    ($session{race_message}) = $te_rm->rows->[0][0] =~ /.*: (.*)/;

    my $te_event = HTML::TableExtract->new( depth => 1, count => 0 );
    $te_event->parse($html);

    unless ($te_event->tables()) { return }; # there may be other tables, if I cared.

    ($session{event}) = $te_event->rows->[0][0];

    Logger->log("event: $session{event}");

    return %session;
}

1;
