package io.github.monadboxlab.clashpseudo.debug;

/** Known test-only JaCoCo outcomes, excluded from the application report. */
public final class CoverageProbe {
    private CoverageProbe() {}

    public static int decision(boolean first, boolean second) {
        if (first && second) return sameLineA();
        return 0;
    }

    public static int sameLineA() { return 1; } public static int sameLineB() { return 2; }
    public static int neverCalled() { return 99; }
}
