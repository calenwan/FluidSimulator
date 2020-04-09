# Fluid Simulator

## CS284A Final Project

## Team Member

- Jiewen Lai
- Kailun Wan
- Yanda Li

## Problem Description
Our ideas come from wathcing the final projects in previous years and we are inspired by the recent lecture of annimation. We are trying to solve is to calculate the locations and movements of fluid particles . With solving this problem, we are able to extensively implement animations nvolves with fluid. The challenging part of this project is how to caculate the movement and positions of the particles as well as ensuring the caculation can be established within reasonable amount of time. We are trying to use the parallel computing to solve the speed issue.
## Goals and Deliverables
 
### Deliverables

1. A scalable particle based fluid simulator that outputs vtk format files.

2. A set of fluid videos generated by 3rd party renderers with the simulation results.

3. A GPU accelerated version simulator. (For aspirationsal plan) 

### Performance metrics:

1. Scalability

This includes weak scaling(performance as particles per processors goes up) and strong scaling(performance as the total number of particles goes up). 

2. Visual effect

Although this is a Computer Graphics project rather than a Physics project, where we are not aiming to simulate all physical properties of fluid, at least we should consider some physical constraints that greatly influence the visual effects to make the rendered results look like real.

3. Latency (for aspirational plan)
If the CUDA acceleration works really well, we can make a realtime/interactive fluid simulator and use simplified rendering technique to preview the results on the fly.


## Schedule
Here is our plan with scheduling the following four weeks for our final project:
Week 1. prepartion for the team and start implementing on the scalable particle simulation.

Week 2. implement the simulation and rendering the fluid particles

Week 3. Debug the previous implementation and record video

Week 4. Work on final report and presentation
## Resources

1. VTK file format
2. paraview
3. cuda
4. Python C interoperation
5. flann
