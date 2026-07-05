# Browser LaTeXML driver. Same conversion as latexml-driver.pl, but tailored for
# the persistent-worker model: reads the input tex from ARGV[0], writes the
# self-contained HTML to ARGV[1], and RETURNS NORMALLY (no POSIX::_exit) so the
# emscripten runtime stays alive and callMain() can be invoked again for the next
# table without recompiling the wasm or reloading the preloaded filesystem.
use strict;
use warnings;
use LaTeXML;
use LaTeXML::Common::Config;

my ($infile, $outfile) = @ARGV;
$infile && $outfile or die "usage: latexml-driver-web.pl <in.tex> <out.html>\n";

my $tex = do {
  open(my $fh, '<:encoding(UTF-8)', $infile) or die "cannot read $infile: $!\n";
  local $/;
  <$fh>;
};

my $opts = LaTeXML::Common::Config->new(
  input_limit => 100,
  format      => 'html5',
  whatsin     => 'document',
  whatsout    => 'document',
  post        => 1,
  mathimages  => 0,
  verbosity   => -1,
);
$opts->check;
my $converter = LaTeXML->get_converter($opts);
$converter->prepare_session($opts);
my $response = $converter->convert("literal:$tex");
die "conversion failed: " . (($response && $response->{status}) || 'no response') . "\n"
  unless $response && $response->{result};

my $html = $response->{result};
$html = $html->toString(1) if ref $html;

# Inline referenced CSS as <style> so the fragment is self-contained.
my $latexml_pm = $INC{'LaTeXML.pm'};
(my $cssdir = $latexml_pm) =~ s{\.pm$}{/resources/CSS};
sub _inline_css {
  my ($href) = @_;
  (my $base = $href) =~ s{.*/}{};
  my $path = "$cssdir/$base";
  return "<!-- css:$base missing -->" unless -f $path;
  my $css = do { open(my $c, '<:encoding(UTF-8)', $path) or return "<!-- css:$base -->"; local $/; <$c> };
  return "<style type=\"text/css\">\n$css</style>";
}
$html =~ s{<link\b[^>]*\brel="stylesheet"[^>]*\bhref="([^"]+)"[^>]*/?>}{_inline_css($1)}ge;

open(my $out, '>:encoding(UTF-8)', $outfile) or die "cannot write $outfile: $!\n";
print {$out} $html;
close $out;
