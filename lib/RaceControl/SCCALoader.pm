package SCCALoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;

use StateLoader;
use HTML::Clean;
use HTML::TableExtract;
use Data::Dumper;

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

    # TODO: This should not be done using html but instead via file that
    #       populates java client

    $html =~ s/\n//g;
    $html =~ s/\&nbsp\;//g;  # get rid of all non breaking spaces
    #$html =~ s/Behind\<br\>Leader/BehindLeader/;
    #$html =~ s/Behind\<br\>Position/BehindPosition/;

    # headers which determine what table is extracted
    my @headers = ('P', 'No.', 'CLS', 'DRIVER NAME', 'BESTIME','DIFF', 'GAP', '#', 'Class', 'F. Name', 'L. Name', 'Yr.', 'Model', 'Disp.', 'Best Time', 'Last Lap', 'Gap', 'Laps' );

    # what is used for the hash labels. This should be passed to this object
    @hashkeys = qw(position car class driver best_lap interval gap class_pos first_name last_name year model displacement best_lap last_lap gap laps);

    my $te_pos = HTML::TableExtract->new( headers => [@headers] );
    $te_pos->parse($html);

    unless ($te_pos->tables()) { return }; # there may be other tables, if I cared.

    my %session;

    # made anonymous because of error explained here:
    # http://www.perl.com/pub/a/2002/05/07/mod_perl.html
    my $sub_ref = sub {
        my $row = shift;
        return { map { $hashkeys[$_] => $row->[$_] } (0 .. $#$row) };

    };
    my $pre_count = @{$session{positions}} = map { &$sub_ref($_) } $te_pos->rows;

    my $post_count = @{$session{positions}} = grep { $_->{laps} != 0 } @{$session{positions}};

    #Logger->log("about to dump positions (count: $post_count)");
    #Logger->log(Dumper(@{$session{positions}}));


    # SVRA has drivers appear more than once in same session.
    # ones with 0 laps are to be considered bogus
    my $pos_diff = $pre_count - $post_count;
    if ($pos_diff) {
	Logger->log({level => 'warning',
                 message => "removed $pos_diff drivers as they had zero laps"});
    }


    # convert time from MM:SS to seconds and other clean up
    foreach (@{$session{positions}}) {
        $_->{last_lap} = RaceControl::Utils::time_to_dec($_->{last_lap});
        $_->{best_lap} = RaceControl::Utils::time_to_dec($_->{best_lap});

	# SVRA leader board may have first_name field blank
	# in that case complete name is in last_name field
	if ($_->{first_name}) { 
	    $_->{driver} = "$_->{first_name} $_->{last_name}"
        } else {
	    $_->{driver} = $_->{last_name}
        }
	$_->{status} = 'Run'; # SVRA doesn't appear to pit or anything

	# SVRA apparently has same car numbers, driver name!
	# Need to add year apparently.  Throw in model for good measure
	$_->{id} = sprintf('%s%s%s%s', $_->{car},
                                     $_->{first_name},
			             $_->{last_name},
			             $_->{year},
			             $_->{model});

	#if ($_->{last_name} eq 'Davis') { Logger->log(Dumper($_)) }

	#$_->{class} =~ s/^\s+//;  # remove leading whitespace from class

	#if ($_->{status} eq 'P') {
	#    $_->{status} = 'Pit';
	#} elsif ($_->{status} eq 'R') {
	#    $_->{status} = 'Ret';
	#} elsif ($_->{status} eq '') {
	#    $_->{status} = 'Run';
	#} else {
	#    Logger->log("unknown status (ALMSLoader): |$_->{status}|");
	#}

	#Logger->log(Dumper($_));
    }

    #Logger->log(Dumper(%session));

    my $te_race = HTML::TableExtract->new( depth => 1, count => 0 );
    $te_race->parse($html);

    unless ($te_race->tables()) { return }; # there may be other tables, if I cared.

    #Logger->log(Dumper($te_race->rows));
    $session{event} = $te_race->rows->[0][0];
    #($session{time}) = $te_race->rows->[0][0] =~ /.*:(\d\d:\d\d:\d\d)/;
    #($session{flag}) = $te_race->rows->[0][1] =~ /.*\((.*) Flag\)/;
#    ($session{control_message}) = $te_race->rows->[0][2] =~ /.*: (.*)/;


     #print Dumper($session{time});
     #print Dumper($session{flag});
#     print Dumper($session{control_message});

#    my $te_rm = HTML::TableExtract->new( depth => 0, count => 3 );
#    $te_rm->parse($html);

#    unless ($te_rm->tables()) { return }; # there may be other tables, if I cared.

#    $session{race_message} = $te_rm->rows->[0][1];

    (my $flag) = $html =~ /(\w+)_flag/;

    if ($flag eq 'checker') {
	$flag = 'checkered'
    }

    $session{flag} = ucfirst($flag);
    
    return %session;
}
