package PEF::Front::Validator;
use strict;
use warnings;
use utf8;
use Encode;
use YAML::XS;
use Data::Dumper;
use Carp qw(cluck croak);
use Regexp::Common 'RE_ALL';
use PEF::Front::Captcha;
use PEF::Front::Config;
use base 'Exporter';
our @EXPORT = qw{
  validate
  get_model
  get_method_attrs
};
my %cache;

#{
#	ajax => {
#		$method => {
#			code => sub {},
#			modified => $mtime
#		}
#	}
#}
sub build_validator {
	my $rules         = $_[0];
	my $method_rules  = $rules->{params} || {};
	my $params_rule   = $rules->{extra_params} || 'ignore';
	my %known_params  = (method => undef, ip => undef);
	my %must_params   = (method => undef);
	my $validator_sub = "sub { \n";
	my $jsn           = '$_[0]->';
	my $def           = '$_[1]->';

	for my $pr (keys %$method_rules) {
		my $mr = $method_rules->{$pr};
		$known_params{$pr} = undef;
		if (!ref ($mr) && substr ($mr, 0, 1) eq '$') {
			$mr = $cache{'-base-'}{rules}{params}{substr ($mr, 1)};
		}
		if (ref ($mr) && exists $mr->{base}) {
			substr ($mr->{base}, 0, 1) = '' if substr ($mr->{base}, 0, 1) eq '$';
			my $bmr = $cache{'-base-'}{rules}{params}{$mr->{base}} || {};
			$bmr = {regex => $bmr} unless ref $bmr;
			$mr = {%$bmr, %$mr};
		}
		if (!ref ($mr)) {
			$validator_sub .=
			    "croak {result => 'BADPARAM', answer => 'Mandatory parameter \$1 is absent', "
			  . "answer_args => ['param-$pr']} "
			  . "unless exists $jsn {$pr} ;\n";
			$validator_sub .=
			    "croak {result => 'BADPARAM', answer => 'Bad parameter \$1', "
			  . "answer_args => ['param-$pr']} "
			  . "unless $jsn {$pr} =~ m/$mr/;\n"
			  if $mr ne '';
			$must_params{$pr} = undef;
		} else {
			my $sub_test = '';
			if (exists ($mr->{regex})) {
				$sub_test .=
				    "croak {result => 'BADPARAM', answer => 'Bad parameter \$1', "
				  . "answer_args => ['param-$pr']} "
				  . "unless $jsn {$pr} =~ m/$mr->{regex}/;\n";
			}
			if (exists ($mr->{captcha}) && $mr->{captcha} ne '') {
				$sub_test .=
				    "if($jsn {$pr} ne 'nocheck') {\n"
				  . "\tcroak {result => 'BADPARAM', answer => 'Bad parameter \$1: bad captcha', "
				  . "answer_args => ['param-$pr']}\n"
				  . "\t\tunless PEF::Front::Captcha::check_captcha($jsn {$pr}, $jsn {$mr->{captcha}}) ;\n}\n";
			}
			if (exists ($mr->{type})) {
				if (uc (substr ($mr->{type}, 0, 1)) eq 'F') {
					$sub_test .=
					    "croak {result => 'BADPARAM', answer => 'Bad type parameter \$1', "
					  . "answer_args => ['param-$pr']} "
					  . "unless ref ($jsn {$pr}) eq 'PEF::Front::File';\n";
				} else {
					$sub_test .=
					    "croak {result => 'BADPARAM', answer => 'Bad type parameter \$1', "
					  . "answer_args => ['param-$pr']} "
					  . "unless ref ($jsn {$pr}) eq '"
					  . uc ($mr->{type}) . "';\n";
				}
			}
			if (exists ($mr->{'max-size'})) {
				$sub_test .=
				    "croak {result => 'BADPARAM', answer => 'Parameter \$1 is too big', "
				  . "answer_args => ['param-$pr']}\n"
				  . "\tif ( !ref($jsn {$pr})? length($jsn {$pr}): ref($jsn {$pr}) eq 'HASH'? scalar(keys \%{$jsn {$pr}}): scalar(\@{$jsn {$pr}}) ) >  $mr->{'max-size'};\n";
			}
			if (exists ($mr->{'min-size'})) {
				$sub_test .=
				    "croak {result => 'BADPARAM', answer => 'Parameter \$1 is too short', "
				  . "answer_args => ['param-$pr']}\n"
				  . "\tif ( !ref($jsn {$pr})? length($jsn {$pr}): ref($jsn {$pr}) eq 'HASH'? scalar(keys \%{$jsn {$pr}}): scalar(\@{$jsn {$pr}}) ) <  $mr->{'min-size'};\n";
			}
			if (exists ($mr->{can}) || exists ($mr->{can_string})) {
				my $can = exists ($mr->{can}) ? $mr->{can} : $mr->{can_string};
				my @can = ref ($can)          ? @{$can}    : ($can);
				$sub_test .=
				    "{ my \$found = 0; local \$_; foreach ("
				  . join (", ", map { "'$_'" } @can)
				  . "){ if(\$_ eq $jsn {$pr}) { \$found = 1; last } }\n"
				  . "croak {result => 'BADPARAM', answer => 'Parameter \$1 has not allowed value', "
				  . "answer_args => ['param-$pr']} "
				  . "unless \$found}\n";
			}
			if (exists ($mr->{can_number})) {
				my @can = ref ($mr->{can_number}) ? @{$mr->{can_number}} : ($mr->{can_number});
				$sub_test .=
				    "{ my \$found = 0; local \$_; foreach ("
				  . join (", ", @can)
				  . "){ if(\$_ == $jsn {$pr}) { \$found = 1; last } }\n"
				  . "croak {result => 'BADPARAM', answer => 'Parameter \$1 has not allowed value', "
				  . "answer_args => ['param-$pr']} "
				  . "unless \$found}\n";
			}
			if (exists ($mr->{default}) || exists ($mr->{value})) {
				my $default = exists ($mr->{value}) ? $mr->{value} : $mr->{default};
				my $check_defaults = '';
				if ($default !~ /^($RE{num}{int}|$RE{num}{real})$/) {
					if ($default =~ /^defaults\.([\w\d].*)/) {
						$default        = "$def {$1}";
						$check_defaults = "exists($def {$1})";
					} elsif ($default =~ /^headers\.(.*)/) {
						my $h = $1;
						$h =~ s/\s*$//;
						$h       = quote_var($h);
						$default = "$def {headers}->get_header($h)";
					} elsif ($default =~ /^cookies\.(.*)/) {
						my $c = $1;
						$c =~ s/\s*$//;
						$c              = quote_var($c);
						$default        = "$def {cookies}->{$c}";
						$check_defaults = "exists($def {cookies}->{$c})";
					} else {
						$default =~ s/\s*$//;
						$default = quote_var($default);
					}
				}
				if (exists $mr->{value}) {
					if ($check_defaults) {
						$validator_sub .= "$jsn {$pr} = $default if $check_defaults;\n";
					} else {
						$validator_sub .= "$jsn {$pr} = $default;\n";
					}
				} else {
					$check_defaults .= ' and' if $check_defaults;
					$validator_sub .= "$jsn {$pr} = $default if $check_defaults not exists $jsn {$pr};\n";
				}
			}
			if (exists ($mr->{optional}) && $mr->{optional} eq 'empty') {
				$validator_sub .= "if(exists($jsn {$pr}) and $jsn {$pr} ne '') {\n$sub_test\n}\n";
			} elsif (exists ($mr->{optional}) && $mr->{optional}) {
				$validator_sub .= "if(exists($jsn {$pr})) {\n$sub_test\n}\n";
			} else {
				$must_params{$pr} = undef;
				$validator_sub .=
				    "croak {result => 'BADPARAM', answer => 'Mandatory parameter \$1 is absent', "
				  . "answer_args => ['param-$pr']} "
				  . "unless exists $jsn {$pr} ;\n";
				$validator_sub .= $sub_test;
			}
		}
	}
	if ($params_rule ne 'pass') {
		$validator_sub .=
		    "{my \%known_params; \@known_params{"
		  . join (", ", map { "'$_'" } keys %known_params)
		  . "} = undef;\n"
		  . "for my \$pr(keys \%{\$_[0]}) {";
		if ($params_rule eq 'ignore') {
			$validator_sub .= "if(!exists(\$known_params {\$pr})) { delete $jsn {\$pr} }";
		} elsif ($params_rule eq 'disallow') {
			$validator_sub .=
			    "if(!exists(\$known_params {\$pr})) { "
			  . "croak {result => 'BADPARAM', answer => 'Parameter \$1 is not allowed here', answer_args => ['\$pr']} }";
		}
		$validator_sub .= "}\n}\n";
	}
	$validator_sub .= "\$_[0]\n};";
	$validator_sub;
}

sub quote_var {
	my $s = $_[0];
	my $d = Data::Dumper->new([$s]);
	$d->Terse(1);
	my $qs = $d->Dump;
	substr ($qs, -1, 1, '') if substr ($qs, -1, 1) eq "\n";
	return $qs;
}

sub make_value_parser {
	my $value = $_[0];
	my $ret   = quote_var($value);
	if (substr ($value, 0, 3) eq 'TT ') {
		my $exp = substr ($value, 3);
		$exp =~ quote_var($exp);
		substr ($exp, 0,  1, '') if substr ($exp, 0,  1) eq "'";
		substr ($exp, -1, 1, '') if substr ($exp, -1, 1) eq "'";
		$ret = qq~do {
			my \$tmpl = '[% $exp %]';
			my \$out;
			\$tt->process_simple(\\\$tmpl, \$stash, \\\$out) or
				\$logger->({level => \"error\", message => 'error: $exp - ' . \$tt->error});\n
			\$out;
		}~;
	}
	return $ret;
}

sub make_cookie_parser {
	my ($name, $value) = @_;
	$value = {value => $value} if not ref $value;
	$name = quote_var($name);
	$value->{path} = '/' if not $value->{path};
	my $ret = qq~\t\$http_response->set_cookie($name, {\n~;
	for my $pn (qw/value expires domain path secure max-age httponly/) {
		if (exists $value->{$pn}) {
			$ret .= "\t\t" . quote_var($pn) . ' => ' . make_value_parser($value->{$pn}) . ",\n";
		}
	}
	$ret .= qq~\t});\n~;
	return $ret;
}

sub make_rules_parser {
	my ($start) = @_;
	$start = {redirect => $start} if not ref $start or 'ARRAY' eq ref $start;
	my $sub_int = "sub {\n";
	for my $cmd (keys %$start) {
		if ($cmd eq 'redirect') {
			my $redir = $start->{$cmd};
			$redir = [$redir] if 'ARRAY' ne ref $redir;
			my $rw = "\t{\n";
			for my $r (@$redir) {
				$rw .= "\t\t\$new_location = " . make_value_parser($r) . ";\n\t\tlast if \$new_location;\n";
			}
			$rw .= "\t}\n";
			$sub_int .= $rw;
		} elsif ($cmd eq 'set-cookie') {
			for my $c (keys %{$start->{$cmd}}) {
				$sub_int .= make_cookie_parser($c => $start->{$cmd}{$c});
			}
		} elsif ($cmd eq 'unset-cookie') {
			my $unset = $start->{$cmd};
			$unset = [$unset] if not ref $unset;
			for my $c (@$unset) {
				$sub_int .= make_cookie_parser($c => {value => '', expires => -3600});
			}
		} elsif ($cmd eq 'add-header') {
			for my $h (keys %{$start->{$cmd}}) {
				my $value = make_value_parser($start->{$cmd}{$h});
				$sub_int .= qq~\t\$http_response->add_header(~ . quote_var($h) . qq~, $value);\n~;
			}
		} elsif ($cmd eq 'set-header') {
			for my $h (keys %{$start->{$cmd}}) {
				my $value = make_value_parser($start->{$cmd}{$h});
				$sub_int .= qq~\t\$http_response->set_header(~ . quote_var($h) . qq~, $value);\n~;
			}
		} elsif ($cmd eq 'filter') {
			my $full_func;
			my $use_class;
			if (index ($start->{$cmd}, 'PEF::Core::') == 0) {
				$full_func = $start->{$cmd};
				$use_class = substr ($full_func, 0, rindex ($full_func, "::"));
				$sub_int .= qq~\teval {use $use_class; $full_func(\$response, \$defaults)};\n~;
			} else {
				$full_func = $start->{$cmd};
				$use_class = substr ($full_func, 0, rindex ($full_func, "::"));
				(my $clf = $use_class) =~ s|::|/|g;
				$full_func = app_namespace . "OutFilter::$full_func";
				my $mrf = out_filter_dir . "/$clf.pm";
				$sub_int .= qq~\teval {require '$mrf'; $full_func(\$response, \$defaults)};\n~;
			}
			$sub_int .=
			    qq~\tif (\$@) {\n~
			  . qq~\t\t\$logger->({level => \"error\", message => \"output filter: \" . Dumper($@)});\n~
			  . qq~\t\t\$response = {result => 'INTERR', answer => 'Bad output filter'};\n\t\treturn;~
			  . qq~\n\t}\n~;
		} elsif ($cmd eq 'answer') {
			$sub_int .= qq~\t\$response->{answer} = ~ . make_value_parser($start->{$cmd}) . qq~;\n~;
		}
	}
	$sub_int .= "\t}";
	return $sub_int;
}

sub build_result_processor {
	my $result_rules = $_[0];
	my $result_sub =
	    "sub {\n\tmy (\$response, \$defaults, \$stash, \$http_response, \$tt, \$logger) = \@_;\n"
	  . "\tmy \$new_location;\n"
	  . "\tmy \%rc = (\n";
	my %rc_array;
	for my $rc (keys %{$result_rules}) {
		$result_sub .= "\t" . quote_var($rc) . " => " . make_rules_parser($result_rules->{$rc}) . ",\n";
	}
	$result_sub .=
	    "\t);\n"
	  . "\tmy \$rc;\n"
	  . "\tif (not exists \$rc{\$response->{result}}) {\n"
	  . "\t\tif(exists \$rc{DEFAULT}) { \$rc = 'DEFAULT' }\n"
	  . "\t\telse {\n"
	  . "\t\t\$logger->({level => \"error\", message => \"error: Unexpected result code: '\$response->{result}'\"});\n"
	  . "\t\treturn (undef, {result => 'INTERR', answer => 'Bad result code'});\n"
	  . "\t\t}\n"
	  . "\t} else {\$rc = \$response->{result}}\n"
	  . "\t\$rc{\$rc}->();\n"
	  . "\treturn (\$new_location, \$response);\n" . "}\n";
	print $result_sub;
	return eval $result_sub;
}

sub validate {
	my $json     = $_[0];
	my $defaults = $_[1];
	my $method   = $json->{method}
	  or croak({
			result => 'INTERR',
			answer => 'Unknown method'
		}
	  );
	my $mrf = $method;
	$mrf =~ s/ ([[:lower:]])/\u$1/g;
	$mrf = ucfirst ($mrf);
	my $rules_file = model_dir . "/$mrf.yaml";
	my @stats      = stat ($rules_file);
	croak {
		result => 'INTERR',
		answer => 'Unknown rules file'
	} if !@stats;
	my $base_file = model_dir . "/-base-.yaml";
	my @bfs       = stat ($base_file);

	if (@bfs
		&& (!exists ($cache{'-base-'}) || $cache{'-base-'}{modified} != $bfs[9]))
	{
		%cache = ('-base-' => {modified => $bfs[9]});
		open my $fi, "<",
		  $base_file
		  or croak {
			result      => 'INTERR',
			answer      => 'cant read base rules file: $1',
			answer_args => ["$!"],
		  };
		my $raw_rules;
		read ($fi, $raw_rules, -s $fi);
		close $fi;
		my @new_rules = eval { Load $raw_rules};
		if ($@) {
			cluck $@;
			croak {
				result      => 'INTERR',
				answer      => 'Base rules validation error: $1',
				answer_args => ["$@"]
			};
		} else {
			my $new_rules = $new_rules[0];
			$cache{'-base-'}{rules} = $new_rules;
		}
	}
	if (!exists ($cache{$method}) || $cache{$method}{modified} != $stats[9]) {
		open my $fi, "<",
		  $rules_file
		  or croak {
			result      => 'INTERR',
			answer      => 'cant read rules file: $1',
			answer_args => ["$!"],
		  };
		my $raw_rules;
		read ($fi, $raw_rules, -s $fi);
		close $fi;
		my @new_rules = eval { Load $raw_rules};
		if ($@) {
			cluck $@;
			croak {
				result      => 'INTERR',
				answer      => 'Validator $1 description error: $2',
				answer_args => [$method, "$@"]
			  }
			  if not exists $cache{$method}{code}
			  or not defined $cache{$method}{code};
		} else {
			my $new_rules = $new_rules[0];
			$new_rules->{method} = $method;
			my $validator_sub = build_validator($new_rules);
			eval "\$cache{\$method}{code} = $validator_sub";
			croak {
				result        => 'INTERR',
				answer        => 'Validator $1 error: $2',
				answer_args   => [$method, "$@"],
				validator_sub => $validator_sub
			  }
			  if $@;
			for (keys %$new_rules) {
				$cache{$method}{$_} = $new_rules->{$_} if $_ ne 'code';
			}
			my $model;
			if (!exists $new_rules->{model}) {
				$model = 'rpc_site';
			} else {
				if ($new_rules->{model} =~ /::/) {
					if ($new_rules->{model} =~ /^PEF::Front/) {
						$model = $new_rules->{model};
					} else {
						$model = app_namespace . "Local::$new_rules->{model}";
					}
				} else {
					$model = $new_rules->{model};
				}
			}
			$cache{$method}{model} = $model;
			if (exists $new_rules->{result}) {
				$cache{$method}{result_sub} = build_result_processor($new_rules->{result});
			}
		}
		$cache{$method}{modified} = $stats[9];
	}
	$cache{$method}{code}->($json, $defaults);
}

sub get_method_attrs {
	my $json = $_[0];
	my $method = ref ($json) ? $json->{method} : $json;
	if (exists $cache{$method}{$_[1]}) {
		return $cache{$method}{$_[1]};
	} else {
		return;
	}
}

sub get_model {
	get_method_attrs($_[0] => 'model');
}
1;
