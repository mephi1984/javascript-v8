#!/usr/bin/perl

use Test::More;
use JavaScript::V8;
use Storable qw/ freeze thaw /;
use Data::Dumper;

use utf8;
use strict;
use warnings;

my $context = JavaScript::V8::Context->new( bless_prefix => 'JS::' );

$context->bind( warn => sub { warn(@_) });

my $COUNTER_SRC = <<'END';
function Counter() {
    this.val = 1;
    this.prev = [];
}

Counter.prototype.inc = function() {
    this.prev.push(this.val);
    this.val++;
}

Counter.prototype.get = function() {
    return this.val;
}

Counter.prototype.set = function(newVal) {
    this.prev.push(this.val);
    this.val = newVal;
}

Counter.prototype.copyFrom = function(otherCounter) {
    this.set(otherCounter.get());
}

Counter.prototype.returnThis = function() {
    return this;
}

Counter.prototype.returnArg = function(v) {
    return v;
}

Counter.prototype.error = function() {
    throw 'SomeError';
}

Counter.prototype.previousValues = function() {
    return this.prev;
}

Counter.prototype.previousValues.__perlReturnsList = true;

Counter.prototype.__perlPackage = "Counter";

Counter.prototype.STORABLE_freeze = function(obj, cloning) {
    return JSON.stringify(obj);
}

Counter.prototype.STORABLE_attach = function(klass, cloning, serialized) {
    var clone = new Counter();
    var data = JSON.parse(serialized);
    for (var k in data)
        if (data.hasOwnProperty(k))
            clone[k] = data[k];
    return clone;
}

Counter.prototype.methodVsFunctionTest = function(arg) {
    return [this, arg];
}

new Counter;
END

my $c1 = $context->eval($COUNTER_SRC, 'counter.js');

isa_ok $c1, 'JS::Counter::N1';
is $c1->get, 1, 'initial value';

$c1->inc;
$c1->inc;

is $c1->get, 3, 'method calls work';

$c1->set('8');

is $c1->get, 8, 'method with an argument';

eval { $c1->error };
like $@, qr{SomeError.*at counter\.js:\d+}, 'js method error propagates to perl';

{
    my $c2 = $context->eval('new Counter');

    $c2->copyFrom($c1);
    $c2->inc;

    is $c2->get, 9, 'converting perl object wrapper back to js';
}

{
    my $context = JavaScript::V8::Context->new( enable_blessing => 1 );
    
    $context->eval($COUNTER_SRC);
    my $c = $context->eval('new Counter()');

    isa_ok $c, 'Counter::N2', 'enable_blessing option works';
}

{
    my $context = JavaScript::V8::Context->new;
    
    $context->eval($COUNTER_SRC);
    my $c = $context->eval('var c = new Counter(); c.set(77); c');

    ok !eval { $c->isa('Counter::N3') }, 'no blessing without enable_blessing or bless_prefix options';
    is $c->{val}, 77, 'no blessing, object converted as data';
}

{
    my $context = JavaScript::V8::Context->new(enable_blessing => 1);
    
    $context->eval($COUNTER_SRC);

    my $c = $context->eval('var c = new Counter(); c.set(77); c');
    my $c4 = $c->returnArg($c);

    isa_ok $c->returnThis->returnThis->returnArg($c), 'Counter::N4', 'chained object returns';
    is $c->returnThis->returnThis, $c, 'object is converted once';
}

{
    my $c = do {
        my $context = JavaScript::V8::Context->new(enable_blessing => 1);
        $context->eval($COUNTER_SRC);
        $context->eval('var c = new Counter(); c.set(77); c');
    };

    is $c->get, 77, 'live object keeps context alive';
}

{
    my $context = JavaScript::V8::Context->new( enable_blessing => 1, enable_wantarray => 1 );
    
    $context->eval($COUNTER_SRC);

    my $c = $context->eval('var c = new Counter(); c.set(77); c.inc(); c.inc(); c');
    is_deeply [$c->previousValues], [1, 77, 78], 'method in list context';
}


{
    my $context = JavaScript::V8::Context->new( enable_blessing => 1, enable_wantarray => 1 );

    $context->eval($COUNTER_SRC);

    my $c = $context->eval('var c = new Counter(); c.set(77); c.inc(); c.inc(); c');
    is_deeply [thaw(freeze($c))->previousValues], [$c->previousValues], 'freeze/thaw work';

    $context->eval('Z = 1');

    my $pkg = ref $c;
    # this is bound to global
    is((eval "${pkg}::methodVsFunctionTest(1)")->[0]{Z}, 1, 'js function called as an package function');
    is((eval "${pkg}::methodVsFunctionTest(1)")->[1], 1);

    # this is bound to $c
    is $c->methodVsFunctionTest(1)->[0], $c;
    is $c->methodVsFunctionTest(1)->[1], 1;
}

done_testing;
