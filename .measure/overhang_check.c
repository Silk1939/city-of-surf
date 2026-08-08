// Unabhaengige Gegenprobe zum Ueberhang-Nachweis: ruft WaveProfile.h direkt aus C auf,
// nicht ueber den Swift-Bridging-Header. Zaehlt die Schnitte einer Senkrechten in (z, y).
#include "../city of surf/WaveProfile.h"
#include <stdio.h>

#define N 40000

static void report(float thetaDeg) {
    HeroWaveParams p = heroWaveDefaultParams();
    p.thetaMaxDegrees = thetaDeg;
    p = heroWaveResolve(p);

    static float zs[N + 1], ys[N + 1];
    float zMin = 1e9f, zMax = -1e9f;
    for (int i = 0; i <= N; ++i) {
        float u = (float)i / (float)N;
        HeroFloat3 w = heroWaveWorldPosition(p, u, 0.5f);
        zs[i] = w.z; ys[i] = w.y;
        if (w.z < zMin) zMin = w.z;
        if (w.z > zMax) zMax = w.z;
    }

    int maxHits = 0; float maxHitsZ = 0; float hitY[8];
    float bandLo = 1e9f, bandHi = -1e9f;   // Band mit >= 2 Schnitten
    for (int k = 0; k <= 4000; ++k) {
        float z = zMin + (zMax - zMin) * (float)k / 4000.0f;
        int hits = 0; float ysAt[8];
        for (int i = 1; i <= N; ++i) {
            if ((zs[i - 1] - z) * (zs[i] - z) < 0.0f) {
                if (hits < 8) ysAt[hits] = ys[i];
                hits++;
            }
        }
        if (hits >= 2) { if (z < bandLo) bandLo = z; if (z > bandHi) bandHi = z; }
        if (hits > maxHits) {
            maxHits = hits; maxHitsZ = z;
            for (int j = 0; j < hits && j < 8; ++j) hitY[j] = ysAt[j];
        }
    }
    printf("thetaMax=%6.1f deg  max Schnitte=%d  bei z=%.3f  Ueberhangband=%.3f m",
           thetaDeg, maxHits, maxHitsZ, (bandHi > bandLo) ? (bandHi - bandLo) : 0.0f);
    if (maxHits >= 2) {
        printf("  Hoehen:");
        for (int j = 0; j < maxHits && j < 8; ++j) printf(" %.3f", hitY[j]);
    }
    printf("\n");
}

int main(void) {
    printf("Gegenprobe aus reinem C, gleicher Header wie Swift und Metal\n");
    report(230.0f);
    report(270.0f);
    report(280.0f);
    report(330.0f);
    return 0;
}
