#include "cudaFluid.cuh"
#include <cmath>
#include <cstdio>

#ifdef BUILD_CUDA

__global__ void simulate_update_position_predict_position(
  int n,
  Vector3R *particle_positions, 
  Vector3R *particle_preditced_position, 
  Vector3R *particle_velocities, 
  const Vector3R &external_accelerations, 
  REAL delta_t
) {
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += blockDim.x * gridDim.x) {
    auto &positions_i = particle_positions[i];
    auto &velocities_i = particle_velocities[i];
    auto &preditced_positions_i = particle_preditced_position[i];
    if (i == 0) {
      printf("Thread 0 position: (%lf, %lf, %lf), acc: (%lf, %lf, %lf), delta_t: %lf\n", 
        positions_i.x, positions_i.y, positions_i.z,
        external_accelerations.x, external_accelerations.y, external_accelerations.z,
        delta_t
      );
    }
    velocities_i += external_accelerations * delta_t;
    preditced_positions_i = positions_i + velocities_i * delta_t;
  }
}

__global__ void calculate_lambda(
  int n,
  Vector3R *particle_positions,
  int **neighbor_search_results,
  int *neighbor_results_size,
  REAL particle_mass,
  REAL density,
  REAL epsilon,
  REAL h,
  REAL *lambda
) {
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += blockDim.x * gridDim.x) {
    const auto &p_i = particle_positions[i];
    // line 10: calculate lambda
    const int *neighbors_i = neighbor_search_results[i];
    const int neighbors_size_i = neighbor_results_size[i];
    // Eq 2
    REAL rho_i = 0;
    for (int jj = 0; jj <  neighbors_size_i; jj++) {
      int j = neighbors_i[jj];
      const auto &p_j = particle_positions[j];
      rho_i += W_poly6(p_i-p_j, h);
    }
    // add itself
    rho_i += W_poly6(p_i-p_i, h);
    rho_i *= particle_mass;
    // Eq 1
    const REAL C_i = rho_i / density - 1.;
    REAL C_i_p_k_2_sum = 0;
    // Eq 8
    // if k = j
    REAL C_i_p_k_j_2 = 0;
    // if k = i
    Vector3R C_i_p_k_i;
    for (int jj = 0; jj < neighbors_size_i; jj++) {
      int j = neighbors_i[jj];
      const auto &p_j = particle_positions[j];
      const auto W_spiky_gradient_i_j = W_spiky_gradient(p_i-p_j, h) * (p_i-p_j);
      C_i_p_k_i += W_spiky_gradient_i_j;
      C_i_p_k_j_2 += W_spiky_gradient_i_j.norm2();
    }
    C_i_p_k_2_sum += C_i_p_k_i.norm2();
    C_i_p_k_2_sum /= pow(density, 2);
    lambda[i] = - C_i / (C_i_p_k_2_sum+epsilon);
  }
}

void copy_predicted_positions_to_position(
  REAL3 *particle_position,
  REAL3 *particle_preditced_position, 
  size_t N
) {
  cudaMemcpy(particle_position, particle_preditced_position, N, cudaMemcpyDeviceToDevice);
}

Fluid_cuda::Fluid_cuda(
  unique_ptr<vector<REAL3>> &&particle_positions,
  REAL h
): nsearch(h) {
  if (particle_positions == nullptr) {
    throw std::runtime_error("particle_positions == nullptr!");
  }
  this->particle_positions = std::move(particle_positions);
}

Fluid_cuda::~Fluid_cuda(){
  cudaFree(particle_positions_device);
  cudaFree(particle_velocities_device);
  cudaFree(particle_preditced_positions_device);
  cudaFree(delta_p_device);
  cudaFree(lambda_device);
  const auto num_particles = particle_positions->size();

  for (int i = 0; i < num_particles; i++) {
    cudaFree(neighbor_search_results_host[i]);
  }
  cudaFree(neighbor_search_results_dev);
}

void Fluid_cuda::init() {
  const auto num_particles = particle_positions->size();
  const auto SIZE_REAL3_N = sizeof(REAL3) * num_particles;

  cudaMalloc(&particle_positions_device, SIZE_REAL3_N);
  cudaMemcpy(particle_positions_device, particle_positions->data(), SIZE_REAL3_N, cudaMemcpyHostToDevice);

  cudaMalloc(&particle_velocities_device, SIZE_REAL3_N);
  cudaMemset(particle_velocities_device, 0, SIZE_REAL3_N);

  cudaMalloc(&particle_preditced_positions_device, SIZE_REAL3_N);
  cudaMalloc(&delta_p_device, SIZE_REAL3_N);
  cudaMalloc(&lambda_device, sizeof(REAL)*num_particles);

  cudaMalloc(&neighbor_search_results_dev, sizeof(int *) * num_particles);
  cudaMalloc(&neighbor_search_results_size_dev, sizeof(int) * num_particles);

  neighbor_search_results_host.resize(num_particles);
  neighbor_search_results_size_host.resize(num_particles);
  std::fill(
    neighbor_search_results_size_host.begin(), 
    neighbor_search_results_size_host.end(), 
    0
  );
  neighbor_search_results_capacity_host.resize(num_particles);
  std::fill(
    neighbor_search_results_capacity_host.begin(), 
    neighbor_search_results_capacity_host.end(), 
    default_capacity
  );

  for (int i = 0; i < num_particles; i++) {
    cudaMalloc(&neighbor_search_results_host[i], sizeof(int)*default_capacity);
  }
  cudaMemcpy(neighbor_search_results_dev, neighbor_search_results_host.data(), sizeof(int *) * num_particles, cudaMemcpyHostToDevice);
  cudaMemcpy(neighbor_search_results_size_dev, neighbor_search_results_size_host.data(), sizeof(int) * num_particles, cudaMemcpyHostToDevice);
  cudaDeviceSynchronize();
  nsearch.add_point_set(
    this->particle_positions->front().data(), 
    this->particle_positions->size(), true, true
  );
  nsearch.find_neighbors();
}

void Fluid_cuda::find_neighbors(){
  int num_particles = particle_positions->size();
  nsearch.find_neighbors();
  for (int i = 0; i < num_particles; i++) {
    // line 6: find neighboring particles
    auto &pointSet = nsearch.point_set(0);
    auto count = pointSet.n_neighbors(0, i);
    int currentCap = neighbor_search_results_capacity_host[i];
    // if it exceeds current device array capacity
    if (count > currentCap) {
      cudaFree(neighbor_search_results_host[i]);
      int newCap = static_cast<int>(count * 1.5);
      cudaMalloc(&neighbor_search_results_host[i], sizeof(int)*newCap);
    }
    // update size in host
    neighbor_search_results_size_host[i] = count;
    // copy into device
    cudaMemcpy(neighbor_search_results_host[i], pointSet.neighbor_list(0, i), sizeof(int)*count, cudaMemcpyHostToDevice);
  }
  // update size to device
  cudaMemcpy(neighbor_search_results_size_dev, neighbor_search_results_size_host.data(), sizeof(int) * num_particles, cudaMemcpyHostToDevice);
  cudaDeviceSynchronize();
}

void Fluid_cuda::simulate(REAL delta_t,
  const FluidParameters *fp,
  vector<CollisionObject *> *collision_objects) {
  int num_particles = particle_positions->size();
  const auto particle_positions_dev = REAL3AsVector3R(particle_positions_device);
  const auto particle_preditced_positions = REAL3AsVector3R(particle_preditced_positions_device);
  const auto particle_velocities = REAL3AsVector3R(particle_velocities_device);
  simulate_update_position_predict_position<<<num_particles,1>>>(
    num_particles,
    particle_positions_dev, 
    particle_preditced_positions, 
    particle_velocities, 
    fp->external_forces, delta_t
  );
  find_neighbors();
  for (int iter = 0; iter < solverIterations; iter++) {
    calculate_lambda<<<<num_particles,1>>>(
      num_particles, 
      particle_positions_dev,
      neighbor_search_results_dev,
      neighbor_search_results_size_dev,
      fp->particle_mass,
      fp->density,
      fp->epsilon,
      fp->h,
      lambda
    );
  }
  const auto SIZE_REAL3_N = sizeof(REAL3) * num_particles;
  copy_predicted_positions_to_position(particle_positions_device, particle_preditced_positions_device, SIZE_REAL3_N);
  // copy result back to host
  cudaMemcpy(particle_positions->data(), particle_positions_device, SIZE_REAL3_N, cudaMemcpyDeviceToHost);
}

#endif