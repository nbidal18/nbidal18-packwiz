package dev.nbidal18.launchguard;

/** Focused URL-policy probe invoked by smoke-test.ps1. */
public final class PackUrlProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || (!args[0].equals("allow") && !args[0].equals("reject"))) {
            throw new IllegalArgumentException("Usage: PackUrlProbe <allow|reject> <URL>");
        }
        boolean expectedAllowed = args[0].equals("allow");
        try {
            LaunchGuard.validatePackUrl(args[1]);
            if (!expectedAllowed) throw new AssertionError("URL was unexpectedly accepted: " + args[1]);
        } catch (GuardException e) {
            if (expectedAllowed) throw new AssertionError("URL was unexpectedly rejected: " + args[1], e);
        }
    }
}
