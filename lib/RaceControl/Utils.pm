package RaceControl::Utils;

sub time_to_dec {
    my ($self, $time) = @_;

    if ($time =~ /(\d*):(\d*\.\d*)/) {
        $time = $1*60 + $2;
    } elsif ($time <= 1) { $time = undef;};  # bogus data.

    return $time;
}

1;
