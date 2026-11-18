<?php
/**
 * Log-in tokens (JSON Web Tokens, HS256): a signed note saying "this is user 5",
 * valid for 7 days. Signed with JWT_SECRET from .env, so nobody can forge one.
 */
declare(strict_types=1);

function base64url_encode(string $data): string
{
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function base64url_decode(string $data): string
{
    return base64_decode(strtr($data, '-_', '+/')) ?: '';
}

/** Creates a token for a user row (user_id, full_name, email). */
function jwt_sign(array $user): string
{
    $header = base64url_encode(json_encode(['alg' => 'HS256', 'typ' => 'JWT']));
    $now = time();
    $payload = base64url_encode(json_encode([
        'id' => (int) $user['user_id'], 'name' => $user['full_name'], 'email' => $user['email'],
        'iat' => $now, 'exp' => $now + 7 * 24 * 3600,
    ]));
    $signature = base64url_encode(hash_hmac('sha256', "$header.$payload", jwt_secret(), true));
    return "$header.$payload.$signature";
}

/** Returns the token's data, or null when it is missing, forged or expired. */
function jwt_verify(string $token): ?array
{
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return null;
    }
    [$header, $payload, $signature] = $parts;
    $expected = base64url_encode(hash_hmac('sha256', "$header.$payload", jwt_secret(), true));
    if (!hash_equals($expected, $signature)) {
        return null;
    }
    $data = json_decode(base64url_decode($payload), true);
    if (!is_array($data) || ($data['exp'] ?? 0) < time()) {
        return null;
    }
    return $data;
}

function jwt_secret(): string
{
    $secret = env('JWT_SECRET');
    if ($secret === null || $secret === '') {
        throw new RuntimeException('JWT_SECRET is not set in backend/.env.');
    }
    return $secret;
}
