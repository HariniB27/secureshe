import os

from app import create_app

app = create_app()

if __name__ == '__main__':
    # PORT: change if 5000 is taken (on macOS AirPlay uses 5000, so use 5050).
    # HOST: set to 0.0.0.0 only when testing on a real phone on the same Wi-Fi.
    #       Debug mode is turned off then, because the debugger must never be
    #       reachable from other devices.
    host = os.getenv('HOST', '127.0.0.1')
    app.run(
        host=host,
        port=int(os.getenv('PORT', '5000')),
        debug=host in ('127.0.0.1', 'localhost'),
    )
