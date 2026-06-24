# imogen

A system to build, publish, and curate Kubernetes node "reference images" in Azure.

<p align="center">
  <img src="assets/imogen.jpg" alt="Imogen, by Herbert Gustave Schmalz" width="240">
</p>

<p align="center">
  <sub>
    <em>Imogen</em> (c. 1888) by Herbert Gustave Schmalz, depicting the heroine of
    Shakespeare's <em>Cymbeline</em>. Public domain, via
    <a href="https://commons.wikimedia.org/wiki/File:Imogen_-_Herbert_Gustave_Schmalz.jpg">Wikimedia Commons</a>.
  </sub>
</p>

## Features

- Finds current Kubernetes releases without corresponding images in a Community Gallery
- Builds missing images for desired operating systems and distros in a Shared Image Gallery (staging)
- Validates the staging images by bringing them up as nodes in a live Kubernetes cluster
- Publishes validated images to the Community Gallery
- Deletes old, unsupported images from the Community Gallery

## Project layout

## Getting started

## Development

## Design

See [docs/plan.md](docs/plan.md) for the design and MVP plan.

