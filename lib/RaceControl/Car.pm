package Car;

#use strict;   OK...found out that this breaks &$key( $self, $props{$key} )
use warnings;

use IO::File;
use Text::CSV_XS;


use Data::Dumper;
use YAML;

#my $file = 'test';
    our @cols = qw(position car class driver status laps gap interval last_lap best_lap best_speed bl_num stops last_stop total_stop model team tires notes tbd1 tbd2 tbd3 tbd4 last_speed total_time tbd5 tbd6 tbd7 tbd8 tbd9 tbd10 tbd11 class_pos pit_lap time_of_day_last_pit fastest_driver total_time_last_lap event_clock_best_lap laps_led avg_speed avg_lap low_speed driver_id tbd12 tbd13 tbd14 laps_down dump_time);

sub init {
    my $dump_name = shift;

    Logger->log("in Car::init  dump_file: $dump_name");
    undef $dump_file;   # close the file if exists
    our $dump_file = IO::File->new("> $dump_name");
    $dump_file->autoflush;

    our $csv = Text::CSV_XS->new ( { eol => $/ } );

    #$csv->combine(@col);
    #print "fields:" . $csv->string() .  "\n";

    $csv->print($dump_file, \@cols);

}

sub END {
    # Logger doesn't exist at this point.  Use print statements.
    if ($dump_file) { 
	print "closing dump_file\n";
        close $dump_file;
    } else {
	print "no dump_file to close\n";
    }
}

sub _dump {
    my ($carref) = shift;

    #print "kernel associated with car: $carref->{gap}\n";    
    #print YAML::Dump($carref);

    my @row;
    foreach my $col (@cols) {
        if (exists $carref->{$col}) {
	    push @row, $carref->{$col};
	} elsif ($col eq 'dump_time') {
	    my $time = localtime;
	    push @row, $time;
        } else {
	    push @row, '';
        }
    }

    $csv->print($dump_file, \@row);

}

sub new {
    my ($class) = shift;
    my (%parms) = @_;

    bless {
	session => $parms{'Session'},
	kernel => $parms{'Kernel'},   # Should have used $poe_kernel instead
	changes => [ 'new' ],
	_dump_file => \$dump_file,
    }, $class;

}

# depending on source of data, properties of a car varies
sub update {
    my ($self, $ref_props) = @_;

    #testing class property
    #print "file: ${$self->{_dump_file}}\n";

    my %props = %$ref_props;

#    $self->{changes} = [];
    
    #print Dumper($self);

    foreach my $key (keys %props) {

	if (defined $self->{$key} and defined $props{$key} and 
                                  $self->{$key} eq $props{$key}) { next; }
	if (! defined($props{$key})) { next; }

#        if (defined &$key and defined $self->{$key} ) { 
        if (defined &$key and ! grep /new/,@{$self->{changes}} ) { 
            &$key( $self, $props{$key} )
        }

        $self->{$key} = $props{$key}; 

    } 

#    print "driver: $self->{driver}  virgin: $self->{virgin}\n";

    # ui needs to be told about everything.  However, don't
    # both announcers unless something changes.


        my %car = %$self;  # neuter
        $car{kernel} = undef;  # strip off uneeded stuff
        $car{session} = undef;
        $self->{kernel}->post( 'ui' => 'car_change' => \%car ); 
        if (@{$self->{changes}}) {
            $self->{kernel}->post( 'booth' => 'notice' => \%car );
	}

#	$self->{kernel}->post( 'logger' => 'log' => \%car );
	#print YAML::Dump(\%car);

	_dump( \%car );

	$self->{changes} = [];


 
}

sub position {
    my ($self, $new) = @_;

    if ($new > $self->{position}) {
        push @{$self->{changes}}, 'position_deprove';  # for future ui update
	#print "Lost: car $self->{car} was $self->{position} now $new\n";
    } else {
        push @{$self->{changes}}, 'position_improve';  # for future ui update
	print "lgoic thinks that position has improved from ".$self->{position}." to $new\n";
    }
}

sub driver {
    my ($self, $new) = @_;

    push @{$self->{changes}}, 'driver';

}

sub status {
    my ($self, $new) = @_;

     push @{$self->{changes}}, 'status_' . lc($new);

}

sub last_lap {
    my ($self, $new) = @_;

    # hmmmmmm.   this probably doesn't work
    #$heap = $self->{kernel}->get_active_session->get_heap();

    my @categories = ( 'overall' );
    if (defined $self->{category}) {
	push @categories, $self->{category}
    }
    
    my $best_overall = 0;
    foreach my $category ( @categories ) {

	my $prev_best = $self->{session}->{best_lap}->{$category};

	#if (!defined $prev_best) { $prev_best = 100000 }

        if (!defined $prev_best or $new < $prev_best) {
	
	    $self->{session}->{best_lap}->{$category} = $new;

            $self->{last_lap_words} = 
                           sprintf("%d minute %.2f", 
			   ($new/60)%60, $new%60 + $new-int($new));

	    if (! $best_overall) {
		push @{$self->{changes}}, 'best_lap_' . lc($category);
            }

	    if ($category eq 'overall') { $best_overall = 1; }

         }
    }
}
sub best_speed {
    my ($self, $new) = @_;

    my $best_overall = 0;
    foreach my $category ( 'overall', $self->{class} ) {

	my $prev_best = $self->{session}->{best_speed}->{$category};

	#if (!defined $prev_best) { $prev_best = 100000 }

        if (!defined $prev_best or $new > $prev_best) {
	
	    $self->{session}->{best_speed}->{$category} = $new;

	    if (! $best_overall) {
		push @{$self->{changes}}, 'best_speed_' . lc($category);
            }

	    if ($category eq 'overall') { $best_overall = 1; }

         }
    }
}

sub gap {
    my ($self, $new) = @_;

    push @{$self->{changes}}, 'gap';

}

sub interval {
    my ($self, $new) = @_;

    push @{$self->{changes}}, 'interval';

}


sub about {
    my ($self) = @_;

    Logger->log("driver: $self->{driver}");

    my %car = %$self;  # neuter
    $car{kernel} = undef;  # strip off uneeded stuff
    $car{session} = undef;

#    $self->{kernel}->post( 'ui' => 'object_passing_test' => $self);  

    $self->{kernel}->post( 'booth' => 'blab' => \%car );

#    $self->{kernel}->post( 'booth' => 'say' => "My name is $self->{driver}");  

}

sub image {
    my ($self) = @_;

    # returns graphic image.  For example, ALMS tracks picture of car, helmets,
    # etc.

    Logger->log("about to retreive graphic of this car");

    if ($self->{series} ne 'ALMS') { return; }

    Logger->log("got an ALMS car, about to look for image");

    # logic to retreive from cache if there or http if it is not
}


1;
