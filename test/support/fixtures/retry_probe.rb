# frozen_string_literal: true

# Genuine finite independent process: caller-owned pipe release or five seconds.
STDIN.read(1) if IO.select([STDIN], nil, nil, 5)
