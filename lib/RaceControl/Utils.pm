package RaceControl::Utils;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# used by *Loader.pm
sub time_to_dec {
    my $time = shift;

    if ($time =~ /(\d*):(\d*\.\d*)/) {
        $time = $1*60 + $2;
    } elsif ($time <= 1) { $time = undef;};  # bogus data.

    return $time;
}

# turn config path into absolute if not already
sub abs_path {
    my $path = shift;

    if (!$path =~ /^\/.*/) {
        $path = $Bin.'/'.$path;
    }

    return $path;
}

1;
