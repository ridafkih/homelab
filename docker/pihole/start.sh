#!/bin/bash

socat UDP4-LISTEN:53,fork UDP4:pihole:53 &
socat TCP4-LISTEN:53,fork TCP4:pihole:53 &

exec /usr/local/bin/containerboot
