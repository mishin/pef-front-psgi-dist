package PEF::Front::SecureCaptcha;

use strict;
use warnings;
use PEF::Front::Config;
use GD::SecurityImage;
use Digest::MD5 qw{md5 md5_hex};
use GDBM_File;
use Storable;
use MLDBM::Sync;
use MLDBM qw(GDBM_File Storable);
use Fcntl qw(:DEFAULT :flock);

sub new {
	my ($class, %args) = @_;
	my $self = {
		width          => 25,
		height         => 34,
		data_folder    => captcha_db,
		output_folder  => www_static_captchas_dir,
		expire         => 300,
		font           => captcha_font,
		symbols        => ["0" .. "9", split //, "abCdEFgHiJKLMNOPqRSTUVWXyZz"],
		security_shift => captcha_secret
	};
	for (qw{width height data_folder output_folder expire font symbols security_shift}) {
		$self->{$_} = $args{$_} if exists $args{$_};
	}
	for (qw{data_folder output_folder}) {
		die "param $_ is required"          unless $self->{$_};
		die "$_ must be directory "         unless -d $self->{$_};
		die "directory $_ must be writable" unless -w $self->{$_};
		$self->{$_} .= "/" unless substr($self->{$_}, -1, 1) eq '/';
	}
	bless $self, $class;
}

sub _random {
	my $max = $_[0];
	open(my $rf, "<", "/dev/urandom") or die $!;
	binmode $rf;
	my $cu;
	sysread($rf, $cu, 8);
	close($rf);
	my $l = unpack "Q", $cu;
	return $l % $max;
}

sub generate_code {
	my ($self, $size) = @_;
	my $str = '';
	my $num = scalar @{$self->{symbols}};
	$str .= $self->{symbols}[_random($num)] for (1 .. $size);
	my $pts   = int($self->{height} / 2.5 + 0.5);
	my $image = GD::SecurityImage->new(
		rndmax   => 1,
		ptsize   => $pts,
		angle    => "0E0",
		scramble => 1,
		lines    => int($size * 1.5 + 0.5),
		width    => $self->{width} * $size,
		height   => $self->{height},
		font     => $self->{font}
	);
	$image->random($str);
	$image->create(ttf => "ec")->particle($self->{width} * $size, 2);
	my ($image_data, $mime_type, $random_number) = $image->out(force => "jpeg");
	my $md5 = md5_hex(lc($str) . $self->{security_shift});
	open(my $oi, ">", "$self->{output_folder}$md5.jpg") or die $!;
	binmode $oi;
	syswrite $oi, $image_data;
	close $oi;
	my %dbm;
	tie(%dbm, 'MLDBM::Sync', "$self->{data_folder}secure_captcha.dbm", O_CREAT | O_RDWR, 0666) or die "$!";
	$dbm{$md5} = time + $self->{expire};
	return $md5;
}

sub check_code {
	my ($self, $code, $md5sum) = @_;
	my $md5 = md5_hex(lc($code) . $self->{security_shift});
	my %dbm;
	my $sync_obj = tie(%dbm, 'MLDBM::Sync', "$self->{data_folder}secure_captcha.dbm", O_CREAT | O_RDWR, 0666) or die "$!";
	$sync_obj->Lock;
	for my $cc (keys %dbm) {
		if ($dbm{$cc} < time) {
			unlink "$self->{output_folder}$cc.jpg";
			delete $dbm{$cc};
		}
	}
	my $passed = 0;
	if (exists $dbm{$md5sum} && $md5sum eq $md5) {
		delete $dbm{$md5sum};
		$passed = 1;
	}
	$sync_obj->UnLock;
	return $passed;
}

1;