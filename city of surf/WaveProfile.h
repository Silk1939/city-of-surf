//
//  WaveProfile.h
//  city of surf
//
//  Profilkurve der Hero-Wave — EINE Quelle der Wahrheit für CPU und GPU.
//
//  Dieser Header wird von `ShaderTypes.h` eingebunden. `ShaderTypes.h` ist zugleich
//  der Swift-Bridging-Header (SWIFT_OBJC_BRIDGING_HEADER) und wird von `Shaders.metal`
//  importiert. Swift und Metal rufen deshalb buchstäblich denselben Code auf; Formeln
//  werden nirgends mehr von Hand gespiegelt.
//
//  WARUM KEINE HÖHENFUNKTION
//  Ein Höhenfeld liefert pro (x, z) genau ein y und kann eine überschlagende Lippe
//  prinzipiell nicht darstellen. Diese Kurve ist deshalb parametrisch:
//
//      theta(t) = thetaMax * g(t)                     Tangentenwinkel, wandert mit t
//      s(t)     = s0 + Integral_0^t r(tau) cos(theta) dtau
//      y(t)     = y0 + Integral_0^t r(tau) sin(theta) dtau
//
//  Sobald theta 90° überschreitet, wird cos(theta) negativ, ds/dt wechselt das
//  Vorzeichen und die Kurve läuft über sich selbst zurück — das ist der Überhang.
//  Jenseits von 270° wird cos(theta) wieder positiv, die Lippe dreht nach vorn ab
//  und eine Senkrechte schneidet die Kurve dreimal: Flanke, Lippenunterseite,
//  Lippenoberseite. GEMESSEN (Kategorie 1, HeroWaveOverhangTests): bei thetaMax = 230°
//  sind es nur 2 Schnitte, ab 280° sind es 3. Der Default steht deshalb auf 330°.
//
//  Die Integration läuft mit FESTER Schrittzahl (HERO_WAVE_PROFILE_STEPS), niemals
//  adaptiv, damit CPU und GPU dieselbe Rechenfolge abarbeiten.
//

#ifndef WaveProfile_h
#define WaveProfile_h

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef metal::float2 HeroFloat2;
typedef metal::float3 HeroFloat3;
#define HERO_MAKE2(a, b)    metal::float2(a, b)
#define HERO_MAKE3(a, b, c) metal::float3(a, b, c)
#define HERO_SIN  metal::sin
#define HERO_COS  metal::cos
#define HERO_POW  metal::pow
#define HERO_FMIN metal::fmin
#define HERO_FMAX metal::fmax
#else
#include <simd/simd.h>
#include <math.h>
typedef simd_float2 HeroFloat2;
typedef simd_float3 HeroFloat3;
#define HERO_MAKE2(a, b)    simd_make_float2(a, b)
#define HERO_MAKE3(a, b, c) simd_make_float3(a, b, c)
#define HERO_SIN  sinf
#define HERO_COS  cosf
#define HERO_POW  powf
#define HERO_FMIN fminf
#define HERO_FMAX fmaxf
#endif

#define HERO_DEG_TO_RAD 0.017453292519943295f

/// Schrittzahl der numerischen Integration. Fest, nicht adaptiv — CPU und GPU müssen
/// dieselbe Folge rechnen. 64 Schritte liegen bei t = 1 um < 3 mm neben 4096 Schritten.
#define HERO_WAVE_PROFILE_STEPS 64

/// Stützstellen für die einmalige Höhennormierung (nur CPU-seitig aufgerufen).
#define HERO_WAVE_SCALE_SAMPLES 96

/// Zentrale Tuning-Struktur der Hero-Wave. Alles in Metern bzw. Grad, damit sich die
/// Welle ohne Shader-Kenntnisse justieren lässt.
typedef struct
{
    /// Kammhöhe über dem Fußpunkt, in Metern. Die Kurve wird am Ende uniform auf
    /// diesen Wert skaliert. Sinnvoll: 4 … 20. Default 9.
    float waveHeight;

    /// Wurfwinkel der Lippe in GRAD: wie weit sich der Tangentenwinkel bis zur
    /// Spitze aufdreht. 90 = senkrechte Wand, > 90 = Überhang, > 270 = die Lippe
    /// dreht nach vorn ab und schließt die Röhre. Sinnvoll: 90 … 350. Default 330.
    float thetaMaxDegrees;

    /// Krümmungsradius der Röhre im Lippenbereich, in Metern — kleine Werte = enge
    /// Röhre. Sinnvoll: 1 … 6. Default 2.6.
    float barrelRadius;

    /// Auslauf des Fußes, in Metern Bogenlänge vom Fußpunkt bis zum Bruchpunkt.
    /// Groß = lange flache Flanke. Sinnvoll: 6 … 30. Default 14.
    float footLength;

    /// Bruchpunkt als normierter Kurvenparameter in [0,1]: ab hier dreht der Winkel
    /// schnell auf. Größer = später und abrupter. Geklemmt auf 0.20 … 0.85.
    /// Default 0.55.
    float breakPhase;

    /// Welt-z des Fußpunkts, in Metern. Die Profilachse s zeigt nach −z, damit der
    /// Kamm hinter dem Fuß liegt und die Lippe nach vorn (+z) überschlägt.
    float footZ;

    /// Halbe Ausdehnung der Sweep-Achse (Welt-x), in Metern. Das Profil wird über
    /// −halfSpanX … +halfSpanX gezogen.
    float halfSpanX;

    /// ABGELEITET, kein Tuning-Wert: uniformer Maßstab, der die Rohkurve auf
    /// `waveHeight` bringt. Wird einmal auf der CPU von `heroWaveResolve()` gefüllt
    /// und mit den Parametern zur GPU geschickt; im Vertex-Shader nur multipliziert.
    float heightScale;
} HeroWaveParams;

/// Defaults. `heightScale` ist 0 und muss durch `heroWaveResolve()` gefüllt werden.
static inline HeroWaveParams heroWaveDefaultParams(void)
{
    HeroWaveParams p;
    p.waveHeight      = 9.0f;
    p.thetaMaxDegrees = 330.0f;
    p.barrelRadius    = 2.6f;
    p.footLength      = 14.0f;
    p.breakPhase      = 0.55f;
    p.footZ           = 0.0f;
    p.halfSpanX       = 15.0f;
    p.heightScale     = 0.0f;
    return p;
}

static inline float heroWaveSmoothstep01(float t)
{
    float c = HERO_FMIN(HERO_FMAX(t, 0.0f), 1.0f);
    return c * c * (3.0f - 2.0f * c);
}

/// Exponent der Winkelrampe g(t) = t^k. k folgt aus dem Bruchpunkt: je später der
/// Bruch, desto steiler dreht der Winkel auf.
static inline float heroWaveRampExponent(HeroWaveParams p)
{
    float bp = HERO_FMIN(HERO_FMAX(p.breakPhase, 0.20f), 0.85f);
    return 1.0f / (1.0f - bp);
}

/// theta(t) in Radiant — Tangentenwinkel gegen die s-Achse.
static inline float heroWaveTangentAngle(HeroWaveParams p, float t)
{
    float thetaMax = p.thetaMaxDegrees * HERO_DEG_TO_RAD;
    return thetaMax * HERO_POW(HERO_FMIN(HERO_FMAX(t, 0.0f), 1.0f), heroWaveRampExponent(p));
}

/// r(t): Bogenlängendichte in Metern pro Einheit t. Lang am Fuß, kurz an der Spitze.
/// Der Lippenwert folgt aus `barrelRadius`, weil der Krümmungsradius r / (dtheta/dt) ist.
static inline float heroWaveArcDensity(HeroWaveParams p, float t)
{
    float bp       = HERO_FMIN(HERO_FMAX(p.breakPhase, 0.20f), 0.85f);
    float thetaMax = p.thetaMaxDegrees * HERO_DEG_TO_RAD;
    float k        = 1.0f / (1.0f - bp);
    float thetaAtBreak = thetaMax * HERO_POW(bp, k);

    float rFoot = HERO_FMAX(p.footLength, 0.5f) / bp;
    float rLip  = HERO_FMAX(p.barrelRadius, 0.05f) * (thetaMax - thetaAtBreak) / (1.0f - bp);

    return rFoot + (rLip - rFoot) * heroWaveSmoothstep01(t);
}

/// Rohkurve (s, y) in Metern, noch nicht auf `waveHeight` normiert.
/// Mittelpunktsregel mit fester Schrittzahl über [0, t].
static inline HeroFloat2 heroWaveProfileRaw(HeroWaveParams p, float t)
{
    float tc = HERO_FMIN(HERO_FMAX(t, 0.0f), 1.0f);
    float h  = tc / (float)HERO_WAVE_PROFILE_STEPS;
    float s  = 0.0f;
    float y  = 0.0f;
    for (int i = 0; i < HERO_WAVE_PROFILE_STEPS; ++i) {
        float tau   = ((float)i + 0.5f) * h;
        float theta = heroWaveTangentAngle(p, tau);
        float r     = heroWaveArcDensity(p, tau);
        s += r * HERO_COS(theta) * h;
        y += r * HERO_SIN(theta) * h;
    }
    return HERO_MAKE2(s, y);
}

/// Uniformer Maßstab, der den Kamm der Rohkurve auf `waveHeight` bringt.
/// Teuer (Stützstellen × Integrationsschritte) — genau einmal auf der CPU aufrufen.
static inline float heroWaveHeightScale(HeroWaveParams p)
{
    float yMax = 1e-4f;
    for (int i = 0; i <= HERO_WAVE_SCALE_SAMPLES; ++i) {
        float t = (float)i / (float)HERO_WAVE_SCALE_SAMPLES;
        yMax = HERO_FMAX(yMax, heroWaveProfileRaw(p, t).y);
    }
    return HERO_FMAX(p.waveHeight, 0.1f) / yMax;
}

/// Füllt `heightScale`. Vor jeder Auswertung und vor dem Upload genau einmal aufrufen.
static inline HeroWaveParams heroWaveResolve(HeroWaveParams p)
{
    HeroWaveParams r = p;
    r.heightScale = heroWaveHeightScale(p);
    return r;
}

/// Normierte Profilkurve (s, y) in Metern. Erwartet gefülltes `heightScale`.
static inline HeroFloat2 heroWaveProfile(HeroWaveParams p, float t)
{
    HeroFloat2 raw = heroWaveProfileRaw(p, t);
    float k = (p.heightScale > 0.0f) ? p.heightScale : 1.0f;
    return HERO_MAKE2(raw.x * k, raw.y * k);
}

/// Weltposition des Sweep-Gitters.
/// u läuft entlang der Profilkurve (0 = Fuß, 1 = Lippenspitze),
/// v entlang der Sweep-Achse (Welt-x, 0 = −halfSpanX, 1 = +halfSpanX).
/// Die Profilachse s zeigt nach −z: der Fuß liegt bei `footZ`, der Kamm dahinter,
/// und die überschlagende Lippe kommt nach +z zurück über den Fuß.
static inline HeroFloat3 heroWaveWorldPosition(HeroWaveParams p, float u, float v)
{
    HeroFloat2 sy = heroWaveProfile(p, u);
    float x = -p.halfSpanX + 2.0f * p.halfSpanX * HERO_FMIN(HERO_FMAX(v, 0.0f), 1.0f);
    return HERO_MAKE3(x, sy.y, p.footZ - sy.x);
}

#endif /* WaveProfile_h */
