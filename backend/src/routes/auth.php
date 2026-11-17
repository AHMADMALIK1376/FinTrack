<?php
/** Sign-up and log-in (AUTH-01 – AUTH-04). Passwords are stored only as bcrypt hashes. */
declare(strict_types=1);

/** POST /api/auth/register  { full_name, email, password } */
function auth_register(): void
{
    $body = request_body();
    $name = trim((string) field($body, 'full_name'));
    $email = strtolower(trim((string) field($body, 'email')));
    $password = (string) field($body, 'password');
    if ($name === '' || $email === '' || strlen($password) < 6) {
        throw new ApiError(400, 'Name, email and a password of at least 6 characters are required.');
    }
    try {
        $user = in_transaction(null, function () use ($name, $email, $password) {
            $user = query_one(
                'INSERT INTO users (full_name, email, password_hash) VALUES (?, ?, ?) RETURNING user_id, full_name, email',
                [$name, $email, password_hash($password, PASSWORD_BCRYPT, ['cost' => 10])]);
            // DB-09: the starter account below is logged as created by the new user
            query("SELECT set_config('app.user_id', ?, true)", [(string) $user['user_id']]);
            $id = $user['user_id'];
            query("INSERT INTO categories (user_id, name, type) VALUES
                (?, 'Salary', 'income'), (?, 'Other Income', 'income'), (?, 'Opening Balance', 'income'),
                (?, 'Food', 'expense'), (?, 'Rent', 'expense'), (?, 'Transport', 'expense'),
                (?, 'Bills', 'expense'), (?, 'Shopping', 'expense'), (?, 'Health', 'expense')", array_fill(0, 9, $id));
            query("INSERT INTO accounts (user_id, account_name, account_type) VALUES (?, 'Cash', 'cash')", [$id]);
            return $user;
        });
    }
    catch (PDOException $error) {
        if (($error->errorInfo[0] ?? '') === '23505') {
            throw new ApiError(409, 'An account with this email already exists.');
        }
        throw $error;
    }
    json_response(['token' => jwt_sign($user), 'user' => $user], 201);
}

/** POST /api/auth/login  { email, password } */
function auth_login(): void
{
    $body = request_body();
    $email = strtolower(trim((string) field($body, 'email')));
    $user = query_one('SELECT * FROM users WHERE email = ?', [$email]);
    // the same message whether the email or the password is wrong, so emails can't be guessed
    if ($user === null || !password_verify((string) field($body, 'password'), $user['password_hash'])) {
        throw new ApiError(401, 'Wrong email or password.');
    }
    json_response(['token' => jwt_sign($user), 'user' => [
        'user_id' => $user['user_id'], 'full_name' => $user['full_name'], 'email' => $user['email'],
    ]]);
}
