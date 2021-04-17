# Build step.
FROM golang:1.16 as build
ADD . /borg
WORKDIR /borg/
RUN go get .
RUN go build -o computer cmd/server/*.go

# Run Step using Distroless.
FROM gcr.io/distroless/base
WORKDIR /borg
COPY --from=build /borg/computer /borg/
ENTRYPOINT [ "/borg/computer" ]