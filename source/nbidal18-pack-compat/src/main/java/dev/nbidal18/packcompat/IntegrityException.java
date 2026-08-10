package dev.nbidal18.packcompat;

final class IntegrityException extends Exception {
    IntegrityException(String message) {
        super(message);
    }

    IntegrityException(String message, Throwable cause) {
        super(message, cause);
    }
}
