# update a win2000 DNS server using gss-tsig 
# tridge@samba.org, October 2002

# jmruiz@animatika.net
# updated, 2004-Enero


# See draft-ietf-dnsext-gss-tsig-02, RFC2845 and RFC2930

use strict;
use lib "GSSAPI-0.12";
use Net::DNS;
use GSSAPI;
use Data::Dumper;

# Integrity of the arguments

if ($#ARGV != 3) {
    print "
Usage: nsupdate-gss.pl HOST DOMAIN IP TTL
";
    exit 1;
}




my $host = $ARGV[0];
my $domain = $ARGV[1];
my $ip = $ARGV[2];
my $ttl = $ARGV[3];
my $alg = "gss.microsoft.com";





#######################################################################
# signing callback function for TSIG module
sub gss_sign($$)
{
    my $key = shift;
    my $data = shift;
    my $sig;
    $key->get_mic(0, $data, $sig);
    return $sig;
}



#####################################################################
# write a string into a file
sub FileSave($$)
{
    my($filename) = shift;
    my($v) = shift;
    local(*FILE);
    open(FILE, ">$filename") || die "can't open $filename";    
    print FILE $v;
    close(FILE);
}


#######################################################################
# verify a TSIG signature from a DNS server reply
#
sub sig_verify($$)
{
    my $context = shift;
    my $packet = shift;

    my $tsig = ($packet->additional)[0];
    print "calling sig_data\n";
    my $sigdata = $tsig->sig_data($packet);

    print "sig_data_done\n";

    return $context->verify_mic($sigdata, $tsig->{"mac"}, 0);
}


#######################################################################
# find the nameserver for the domain
#
sub find_nameservers($)
{
    my $domain = shift;
    my $res = Net::DNS::Resolver->new;
    $res->nameservers($domain);
    return $res;
}


#######################################################################
# find a server name for a domain - currently uses the LDAP SRV record.
# I wonder if there is a _dns record type?
sub find_server_name($)
{
    my $domain = shift;
    my $res = Net::DNS::Resolver->new;
    my $srv_query = $res->query("_ldap._tcp.$domain.", "SRV");
    if (!defined($srv_query)) {
	return undef;
    }
    my $server_name = ($srv_query->answer)[0]->{"target"};
    return $server_name;
}

#######################################################################
# 
#
sub negotiate_tkey($$$$)
{

    my $nameserver = shift;
    my $domain = shift;
    my $server_name = shift;
    my $key_name = shift;

    my $status;

    my $context = GSSAPI::Context->new;
    my $name = GSSAPI::Name->new;

    # use a principal name of dns/server@DOMAIN
    $status = $name->import($name, "dns/" . $server_name . "@" . uc($domain));
    if (! $status) {
	print "import name: $status\n";
	return undef;
    }

    my $flags = 
	GSS_C_REPLAY_FLAG | GSS_C_MUTUAL_FLAG | 
	GSS_C_SEQUENCE_FLAG | GSS_C_CONF_FLAG | 
	GSS_C_INTEG_FLAG | GSS_C_DELEG_FLAG;


    $status = GSSAPI::Cred::acquire_cred(undef, 120, undef, GSS_C_INITIATE,
					 my $cred, my $oidset, my $time);

    if (! $status) {
	print "acquire_cred: $status\n";
	return undef;
    }

    print "creds acquired\n";

    # call gss_init_sec_context()
    $status = $context->init($cred, $name, undef, $flags,
			     0, undef, "", undef, my $tok,
			     undef, undef);
    if (! $status) {
	print "init_sec_context: $status\n";
	return undef;
    }

    print "init done\n";

    my $gss_query = Net::DNS::Packet->new("$key_name", "TKEY", "IN");

    # note that Windows2000 uses a SPNEGO wrapping on GSSAPI data sent to the nameserver.
    # I tested using the gen_negTokenTarg() call from Samba 3.0 and it does work, but
    # for this utility it is better to use plain GSSAPI/krb5 data so as to reduce the
    # dependence on external libraries. If we ever want to sign DNS packets using
    # NTLMSSP instead of krb5 then the SPNEGO wrapper could be used

    print "calling RR new\n";

    $a = Net::DNS::RR->new(
			   Name    => "$key_name",
			   Type    => "TKEY",
			   TTL     => 0,
			   Class   => "ANY",
			   mode => 3,
			   algorithm => $alg,
			   inception => time,
			   expiration => time + 24*60*60,
			   key => $tok,
			   other_data => "",
			   );

    $gss_query->push("answer", $a);

    my $reply = $nameserver->send($gss_query);

    if (!defined($reply) || $reply->header->{'rcode'} ne 'NOERROR') {
	print "failed to send TKEY\n";
	return undef;
    }

    my $key2 = ($reply->answer)[0]->{"key"};

    # call gss_init_sec_context() again. Strictly speaking
    # we should loop until this stops returning CONTINUE
    # but I'm a lazy bastard
    $status = $context->init($cred, $name, undef, $flags,
			     0, undef, $key2, undef, $tok,
			     undef, undef);
    if (! $status) {
	print "init_sec_context step 2: $status\n";
	return undef;
    }

    print "verifying\n";

    # check the signature on the TKEY reply
    my $rc = sig_verify($context, $reply);
    if (! $rc) {
	print "Failed to verify TKEY reply: $rc\n";
#		return undef;
    }

    print "verifying done\n";

    return $context;
}


#######################################################################
# MAIN
#######################################################################


# find the nameservers
my $nameserver = find_nameservers("$domain.");

print "Found nameserver $nameserver\n";

if (!defined($nameserver) || $nameserver->{'errorstring'} ne 'NOERROR') {
    print "Failed to find a nameserver for domain $domain\n";
    exit 1;
}

# find the name of the DNS server
my $server_name = find_server_name($domain);
if (!defined($server_name)) {
    print "Failed to find a DNS server name for $domain\n";
    exit 1;
}
print "Using DNS server name $server_name\n";

# use a long random key name
my $key_name = int(rand 10000000000000);

# negotiate a TKEY key
my $gss_context = negotiate_tkey($nameserver, $domain, $server_name, $key_name);
if (!defined($gss_context)) {
    print "Failed to negotiate a TKEY\n";
    exit 1;
}
print "Negotiated TKEY $key_name\n";

# construct a signed update
my $update = Net::DNS::Update->new($domain);

$update->push("pre", yxdomain("$domain"));
$update->push("update", rr_del("$host.$domain. A"));
$update->push("update", rr_add("$host.$domain. $ttl A $ip"));

my $sig = Net::DNS::RR->new(
			    Name    => $key_name,
			    Type    => "TSIG",
			    TTL     => 0,
			    Class   => "ANY",
			    Algorithm => $alg,
			    Time_Signed => time,
			    Fudge => 36000,
			    Mac_Size => 0,
			    Mac => "",
			    Key => $gss_context,
			    Sign_Func => \&gss_sign,
			    Other_Len => 0,
			    Other_Data => "",
			    Error => 0,
			    );

$update->push("additional", $sig);

# send the dynamic update
my $update_reply = $nameserver->send($update);

if (! defined($update_reply)) {
    print "No reply to dynamic update\n";
    exit 1;
}

# make sure it worked
my $result = $update_reply->header->{"rcode"};
print "Update gave rcode $result\n";

if ($result ne 'NOERROR') {
    exit 1;
}

exit 0;
