.pragma library

// The most characters each kind of field takes (Input.maximumLength): the largest real value plus
// room, so nobody pastes a script into a host name. bin/omaremote-session holds the same numbers
// (LIMITS) for files that arrive by import and sync; tests/test_limits.py keeps the two equal.
// Where the numbers come from: docs/limits.md.

var name = 256        // connection, group and system names: our own labels
var host = 253        // host, gateway: DNS's 255 octets written out; check_host takes no more
var address = 1024    // quick connect and search: scheme, user, host and port together
var hostList = 2048   // KDCs: several host names
var user = 1024       // Windows takes 513 (DOMAIN\user or UPN), AD UPNs up to 1024, Linux 256
var domain = 512      // DNS 255, Windows target names 337
var password = 2048   // Windows up to 1280 (credential blob); SSH sets no limit
var port = 5          // 65535
var size = 5          // width, height: 8192 a monitor, 32766 all together
var args = 4096       // extra ssh and FreeRDP options
var path = 4096       // PATH_MAX
var shortcut = 128

// Any field that names none of the above.
var standard = 256

// How many of each connections.json holds at most: the same as STORE_MAX_* in omaremote-session
// (tests/test_limits.py keeps them equal), which reads no file holding more. The window adds no more.
var count = {
    connections: 2000,
    groups: 200,
    credentials: 200,
    trash: 2000,
    quick: 50
}
